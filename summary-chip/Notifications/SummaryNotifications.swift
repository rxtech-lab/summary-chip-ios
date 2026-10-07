import Foundation
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Shared by the app delegate and the Settings sheet. Extensions don't register for push.
@Observable
final class SummaryNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SummaryNotifications()
    private(set) var authorized = false
    private(set) var busy = false
    private(set) var feedback: String?
    var errorMessage: String?
    private weak var environment: AppEnvironment?
    private var token: String?
    private var generation = 0
    private var acceptsRegistrations = false
    private var registrationTask: Task<Void, Never>?
    private var pending: (route: AppRoute, userId: String)?
    private let center = UNUserNotificationCenter.current()
    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "summaryPushEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "summaryPushEnabled") }
    }
    /// Identifies this device's push registration; Live Activity tokens are registered under it.
    var installationId: String {
        if let id = UserDefaults.standard.string(forKey: "summaryPushInstallationId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "summaryPushInstallationId")
        return id
    }

    func configure(environment: AppEnvironment) {
        self.environment = environment
        center.delegate = self
    }

    func refreshStatus() async {
        let settings = await center.notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Restore registration only when the user has already allowed notifications.
    func synchronize() async {
        await refreshStatus()
        guard environment?.authenticationState == .signedIn else { return }
        acceptsRegistrations = true
        await openPendingSummary()
        if enabled && authorized {
            registerWithApple()
        } else {
            unregisterWithApple()
            await stopLiveActivities()
            try? await environment?.api.unregisterPushDevice(installationId: installationId)
        }
    }

    var isEnabled: Bool { enabled && authorized }

    func enable() async {
        guard !busy else { return }
        guard environment?.authenticationState == .signedIn else { return }
        acceptsRegistrations = true
        busy = true
        feedback = nil
        errorMessage = nil
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
                busy = false
                await refreshStatus()
                errorMessage = String(localized: "Allow notifications for Chippy in system Settings to receive summary alerts.")
                return
            }
            guard acceptsRegistrations, environment?.authenticationState == .signedIn else {
                busy = false
                return
            }
            enabled = true
            await refreshStatus()
            registerWithApple()
        } catch {
            busy = false
            errorMessage = String(localized: "Chippy could not request notification permission. Try again.")
        }
    }

    func disable() async {
        guard !busy else { return }
        busy = true
        feedback = nil
        // Invalidate a registration in flight before removing it.
        generation += 1
        enabled = false
        unregisterWithApple()
        center.removeAllDeliveredNotifications()
        await registrationTask?.value
        await stopLiveActivities()
        do {
            try await environment?.api.unregisterPushDevice(installationId: installationId)
            feedback = String(localized: "Notifications disabled")
        } catch {
            errorMessage = String(localized: "Notifications are disabled on this device. The server could not be updated; Chippy will retry when it becomes active.")
        }
        busy = false
    }

    /// Stop delivery before discarding the signed-in credentials.
    func signOut() async {
        generation += 1
        acceptsRegistrations = false
        pending = nil
        unregisterWithApple()
        center.removeAllDeliveredNotifications()
        await registrationTask?.value
        await stopLiveActivities()
        try? await environment?.api.unregisterPushDevice(installationId: installationId)
        token = nil
        busy = false
    }

    func registered(deviceToken: Data) {
        guard acceptsRegistrations, enabled else { return }
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let currentGeneration = generation
        let previous = registrationTask
        registrationTask = Task {
            await previous?.value
            guard currentGeneration == generation, acceptsRegistrations, enabled, authorized, let environment, environment.authenticationState == .signedIn, let token else { return }
            #if os(iOS)
            let platform = "ios"
            #else
            let platform = "macos"
            #endif
            let pushEnvironment = Self.pushEnvironment
            do {
                try await environment.api.registerPushDevice(installationId: installationId, token: token, environment: pushEnvironment, platform: platform)
                guard currentGeneration == generation else { return }
                #if os(iOS)
                // The backend only takes Live Activity tokens for a registered installation.
                FlightLiveActivities.shared.start(api: environment.api, installationId: installationId, environment: pushEnvironment)
                #endif
                if busy { feedback = String(localized: "Notifications enabled") }
                busy = false
            } catch {
                guard currentGeneration == generation else { return }
                registrationFailed()
            }
        }
    }

    func registrationFailed() {
        guard acceptsRegistrations, enabled else { return }
        busy = false
        errorMessage = String(localized: "Chippy could not register for notifications. Try again when you are online.")
    }

    func clearFeedback() { feedback = nil }

    /// `sandbox` for development builds, else `production`.
    static var pushEnvironment: String {
        Bundle.main.object(forInfoDictionaryKey: "SummaryChipPushEnvironment") as? String == "development" ? "sandbox" : "production"
    }

    private func stopLiveActivities() async {
        #if os(iOS)
        await FlightLiveActivities.shared.stop()
        #endif
    }

    private func registerWithApple() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private func unregisterWithApple() {
        #if os(iOS)
        UIApplication.shared.unregisterForRemoteNotifications()
        #else
        NSApplication.shared.unregisterForRemoteNotifications()
        #endif
    }

    private func openPendingSummary() async {
        guard let pending, let environment, environment.authenticationState == .signedIn else { return }
        self.pending = nil
        guard (try? await environment.tokenBroker.currentBundle()?.subject) == pending.userId,
              environment.authenticationState == .signedIn else { return }
        environment.pendingRoute = pending.route
        await environment.library.reload()
    }

    // Completion-handler variants: the async ones are bridged on a background executor, and
    // UIKit asserts (SIGABRT) when their completion runs off the main thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let userId = notification.request.content.userInfo["userId"] as? String
        let tripId = notification.request.content.userInfo["tripId"] as? String
        Task { @MainActor in
            completionHandler(await self.presentationOptions(userId: userId, tripId: tripId))
        }
    }

    private func presentationOptions(userId: String?, tripId: String?) async -> UNNotificationPresentationOptions {
        guard enabled, let userId, let environment, environment.authenticationState == .signedIn,
              (try? await environment.tokenBroker.currentBundle()?.subject) == userId else { return [] }
        // An open trip reloads itself and its flights (trip updates, flight alerts).
        if let tripId { NotificationCenter.default.post(name: .summaryTripPushReceived, object: tripId) }
        await environment.library.reload()
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let info = response.notification.request.content.userInfo
        let userId = info["userId"] as? String
        // A trip update carries both ids; the trip opens as a diary, not a summary.
        let route: AppRoute? = if let tripId = info["tripId"] as? String {
            .tripID(tripId)
        } else if let summaryId = info["summaryId"] as? String {
            .summaryID(summaryId)
        } else {
            nil
        }
        Task { @MainActor in
            if let userId, let route { await self.received(route, userId: userId) }
            completionHandler()
        }
    }

    private func received(_ route: AppRoute, userId: String) async {
        pending = (route, userId)
        await openPendingSummary()
    }
}

extension Notification.Name {
    /// A push about a trip arrived while the app is open; `object` is the trip id.
    static let summaryTripPushReceived = Notification.Name("summaryTripPushReceived")
}

#if os(iOS)
final class SummaryAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SummaryNotifications.shared.registered(deviceToken: deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SummaryNotifications.shared.registrationFailed()
    }
}
#else
final class SummaryAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SummaryNotifications.shared.registered(deviceToken: deviceToken)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SummaryNotifications.shared.registrationFailed()
    }
}
#endif
