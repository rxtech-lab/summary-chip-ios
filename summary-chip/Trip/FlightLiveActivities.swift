#if os(iOS)
import ActivityKit
import Foundation
import os
import SummaryKit

/// Keeps the backend in step with this device's flight Live Activities: the push-to-start token
/// (so the backend can start one 4 hours before departure), each running activity's update token,
/// and their removal when an activity ends. Runs while signed in with notifications on, after the
/// device is registered for push (the backend requires it).
///
/// When the app has a trip's flights in hand and one departs soon, it starts the activity itself
/// rather than waiting for the push; registering its token tells the backend not to start another.
final class FlightLiveActivities {
    static let shared = FlightLiveActivities()

    private var api: SummaryAPIClient?
    private var installationId: String?
    private var pushEnvironment = "production"
    private var observers: [Task<Void, Never>] = []
    /// Token and state observers per activity id.
    private var activityObservers: [String: [Task<Void, Never>]] = [:]

    private static let log = Logger(subsystem: "com.rxlab.summary-chip", category: "LiveActivity")
    private static let startWindow: TimeInterval = 4 * 60 * 60
    private static let afterLanding: TimeInterval = 15 * 60

    private var activities: [Activity<FlightActivityAttributes>] { Activity<FlightActivityAttributes>.activities }

    /// Starts observing tokens; repeated calls for the same installation are ignored.
    func start(api: SummaryAPIClient, installationId: String, environment: String) {
        guard self.api == nil || self.installationId != installationId else { return }
        cancelObservers()
        self.api = api
        self.installationId = installationId
        self.pushEnvironment = environment
        endDuplicates()
        observers.append(Task { [weak self] in
            for await data in Activity<FlightActivityAttributes>.pushToStartTokenUpdates {
                guard let self, let api = self.api, let installationId = self.installationId else { return }
                do {
                    try await api.registerLiveActivityStartToken(installationId: installationId, token: data.hexString)
                } catch {
                    Self.log.error("Registering the Live Activity start token failed: \(String(describing: error), privacy: .public)")
                }
            }
        })
        observers.append(Task { [weak self] in
            for await activity in Activity<FlightActivityAttributes>.activityUpdates {
                guard let self else { return }
                self.observe(activity)
                self.endDuplicates()
            }
        })
        for activity in activities { observe(activity) }
    }

    /// Stops observing, ends this device's flight activities and clears its tokens on the backend.
    /// Call before the push installation is unregistered.
    func stop() async {
        let api = api, installationId = installationId
        cancelObservers()
        self.api = nil
        self.installationId = nil
        for activity in activities {
            if let api, let installationId {
                try? await api.unregisterFlightLiveActivity(flightId: activity.attributes.flightId, installationId: installationId)
            }
            await Self.end(activityID: activity.id)
        }
        if let api, let installationId {
            try? await api.registerLiveActivityStartToken(installationId: installationId, token: nil)
        }
    }

    /// Starts an activity for each found flight of the trip departing within 4 hours (and not yet
    /// 15 minutes past landing) that has none on this device.
    func startIfDue(_ flights: [TripFlight], tripId: String, now: Date = Date()) {
        guard api != nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        var running = Set(activities.filter { $0.activityState == .active || $0.activityState == .stale }.map(\.attributes.flightId))
        for item in flights where item.state == .found {
            guard let flight = item.flight, !running.contains(flight.id),
                  ![FlightStatus.cancelled, .diverted].contains(flight.status),
                  let state = FlightActivityAttributes.ContentState(flight: flight) else { continue }
            let landing = flight.arrival.actual ?? state.arrivalBestDate
            guard state.departureBestDate.timeIntervalSince(now) <= Self.startWindow,
                  now < landing.addingTimeInterval(Self.afterLanding) else { continue }
            do {
                let activity = try Activity.request(
                    attributes: FlightActivityAttributes(flight: flight, tripId: tripId),
                    content: ActivityContent(state: state, staleDate: landing.addingTimeInterval(Self.afterLanding)),
                    pushType: .token
                )
                running.insert(flight.id)
                observe(activity)
            } catch {
                Self.log.error("Starting the Live Activity for \(flight.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Observing

    private func observe(_ activity: Activity<FlightActivityAttributes>) {
        guard activityObservers[activity.id] == nil else { return }
        let flightId = activity.attributes.flightId
        activityObservers[activity.id] = [
            Task { [weak self] in
                for await token in activity.pushTokenUpdates {
                    await self?.register(token: token, flightId: flightId)
                }
            },
            Task { [weak self] in
                for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                    await self?.ended(activityID: activity.id, flightId: flightId)
                    return
                }
            },
        ]
    }

    private func register(token: Data, flightId: String) async {
        guard let api, let installationId else { return }
        do {
            try await api.registerFlightLiveActivity(flightId: flightId, installationId: installationId, token: token.hexString, environment: pushEnvironment)
        } catch {
            Self.log.error("Registering the Live Activity for \(flightId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Clears the token unless another activity still shows the flight (an ended duplicate).
    private func ended(activityID: String, flightId: String) async {
        activityObservers.removeValue(forKey: activityID)?.forEach { $0.cancel() }
        let stillShown = activities.contains {
            $0.id != activityID && $0.attributes.flightId == flightId && ($0.activityState == .active || $0.activityState == .stale)
        }
        guard !stillShown, let api, let installationId else { return }
        try? await api.unregisterFlightLiveActivity(flightId: flightId, installationId: installationId)
    }

    /// A push-to-start and a local start can race; keep one activity per flight and point the
    /// backend at its token.
    private func endDuplicates() {
        var kept: [String: Activity<FlightActivityAttributes>] = [:]
        for activity in activities where activity.activityState == .active || activity.activityState == .stale {
            let flightId = activity.attributes.flightId
            guard let keeper = kept[flightId] else {
                kept[flightId] = activity
                continue
            }
            let activityID = activity.id
            let token = keeper.pushToken
            Task { [weak self] in
                await Self.end(activityID: activityID)
                if let token { await self?.register(token: token, flightId: flightId) }
            }
        }
    }

    /// Activities aren't `Sendable`; look the activity up where it's ended.
    @concurrent nonisolated private static func end(activityID: String) async {
        guard let activity = Activity<FlightActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func cancelObservers() {
        observers.forEach { $0.cancel() }
        observers = []
        activityObservers.values.flatMap { $0 }.forEach { $0.cancel() }
        activityObservers = [:]
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
#endif
