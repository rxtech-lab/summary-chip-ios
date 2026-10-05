import CoreLocation
import Observation

/// When-in-use location for trips: a one-shot fix (opening on the nearest day, "Use current
/// location") and live updates while a trip is on screen. Never asks for permission by itself;
/// `requestAccess()` does, from a user action.
@Observable
final class LocationProvider {
    private(set) var location: CLLocation?
    private(set) var authorization: CLAuthorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()
    #if os(iOS)
    @ObservationIgnored private var session: CLServiceSession?
    #else
    @ObservationIgnored private var session: Bool?
    #endif
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    init() {
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        #if os(iOS)
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
        #else
        authorization == .authorized || authorization == .authorizedAlways
        #endif
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func refreshAuthorization() {
        authorization = manager.authorizationStatus
    }

    /// Asks for when-in-use access (shows the system prompt the first time) and starts live updates.
    func requestAccess() {
        #if os(iOS)
        if session == nil { session = CLServiceSession(authorization: .whenInUse) }
        #else
        if session == nil {
            session = true
            manager.requestWhenInUseAuthorization()
        }
        #endif
        startLiveUpdates()
    }

    /// Follows the user while a trip is visible. Does nothing until access was granted.
    func startLiveUpdates() {
        refreshAuthorization()
        guard liveTask == nil, isAuthorized || session != nil else { return }
        liveTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    self.refreshAuthorization()
                    if let location = update.location { self.location = location }
                    if update.authorizationDenied || update.authorizationDeniedGlobally { break }
                }
            } catch {}
            self?.liveTask = nil
        }
    }

    func stopLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
        session = nil
    }

    /// The current position, waiting up to `timeout` for a fix. Nil without access.
    func currentLocation(timeout: Duration = .seconds(8)) async -> CLLocation? {
        refreshAuthorization()
        if let location, location.timestamp.timeIntervalSinceNow > -120 { return location }
        guard isAuthorized || session != nil else { return nil }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                        if update.authorizationDenied || update.authorizationDeniedGlobally { return nil }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { location = first }
            return first
        }
    }
}
