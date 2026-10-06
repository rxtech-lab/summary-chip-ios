import Foundation
import Observation

/// The running app's version, sent with every request to Chippy's server so it can answer
/// `426 APP_UPDATE_REQUIRED` for features this build can't handle (server `lib/http/app-version.ts`).
public enum AppVersion {
    /// `CFBundleShortVersionString`. Extensions share the app's version (`MARKETING_VERSION`).
    public static let current: String? = info("CFBundleShortVersionString")
    /// `CFBundleVersion`.
    public static let build: String? = info("CFBundleVersion")

    public static var platform: String {
        #if os(visionOS)
        "visionos"
        #elseif os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    private static func info(_ key: String) -> String? {
        SummaryConfiguration.sanitized(Bundle.main.object(forInfoDictionaryKey: key) as? String)
    }
}

extension URLRequest {
    /// Adds `X-App-Version`, `X-App-Build` and `X-App-Platform`.
    mutating func setAppVersionHeaders() {
        if let version = AppVersion.current { setValue(version, forHTTPHeaderField: "X-App-Version") }
        if let build = AppVersion.build { setValue(build, forHTTPHeaderField: "X-App-Build") }
        setValue(AppVersion.platform, forHTTPHeaderField: "X-App-Platform")
    }
}

/// A server feature this app version is too old for (`426 APP_UPDATE_REQUIRED`).
public struct AppUpdateRequirement: Sendable, Hashable, Identifiable {
    /// The oldest version that supports the feature, e.g. `1.9.0`.
    public var requiredVersion: String
    public var feature: String?
    /// The App Store listing (iOS) or Mac download, when the server knows it.
    public var updateURL: URL?

    public var id: String { requiredVersion }
}

/// Collects update requirements from any API call so the app can show one alert for them.
@MainActor
@Observable
public final class AppUpdateCenter {
    public static let shared = AppUpdateCenter()

    /// The pending requirement; set back to nil once the alert is dismissed.
    public var requirement: AppUpdateRequirement?

    private init() {}

    nonisolated static func report(_ error: SummaryAPIError) {
        guard let requirement = error.appUpdateRequirement else { return }
        SummaryLog.api.notice("Server needs app \(requirement.requiredVersion, privacy: .public) (running \(AppVersion.current ?? "?", privacy: .public))")
        Task { @MainActor in
            // Keep the newest version asked for while an alert is up.
            if let pending = shared.requirement,
               pending.requiredVersion.compare(requirement.requiredVersion, options: .numeric) != .orderedAscending { return }
            shared.requirement = requirement
        }
    }
}
