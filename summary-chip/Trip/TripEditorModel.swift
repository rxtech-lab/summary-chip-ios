import Foundation
import Observation
import SummaryKit

/// One trip diary being viewed and edited. Edits are whole-document `PUT`s carrying the revision
/// they were made on; when the agent (or another device) saved in between, the trip is reloaded,
/// the edit is reapplied to the fresh copy and saved again.
@Observable
final class TripEditorModel {
    /// A short-lived notice over the trip after something happened outside the current sheet.
    enum Notice: Equatable {
        case reloaded
        case deleting
        case generatingCover
        case coverUpdated
        case agentDone
        case syncingCalendar
        case calendarSynced
        case calendarRemoved

        var message: String {
            switch self {
            case .reloaded: String(localized: "Updated elsewhere — reloaded")
            case .deleting: String(localized: "Deleting trip…")
            case .generatingCover: String(localized: "Designing a new cover…")
            case .coverUpdated: String(localized: "New cover ready")
            case .agentDone: String(localized: "Trip agent updated the trip")
            case .syncingCalendar: String(localized: "Updating your calendar…")
            case .calendarSynced: String(localized: "Calendar updated")
            case .calendarRemoved: String(localized: "Removed from calendar")
            }
        }

        var systemImage: String {
            switch self {
            case .reloaded: "arrow.triangle.2.circlepath"
            case .deleting, .generatingCover, .syncingCalendar: "hourglass"
            case .coverUpdated, .agentDone, .calendarSynced, .calendarRemoved: "checkmark.circle"
            }
        }

        var isWorking: Bool { [.deleting, .generatingCover, .syncingCalendar].contains(self) }
    }

    let api: SummaryAPIClient
    let id: String
    private(set) var trip: Trip?
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var notice: Notice?
    /// Bumped after every successful save, for haptics.
    private(set) var savedCount = 0
    /// The trip's tracked flight segments, as the backend last stored them.
    private(set) var flights: [TripFlight] = []

    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFlightsTask: Task<Void, Never>?

    init(api: SummaryAPIClient, id: String) {
        self.api = api
        self.id = id
    }

    var document: TripDocument? { trip?.document }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            trip = try await api.trip(id: id)
            loadError = nil
            await loadFlights()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if trip == nil { loadError = error.localizedDescription }
        }
    }

    /// Applies `edit` to the current document and saves it. Throws when the save fails; the
    /// caller's sheet stays open to show the error.
    func update(_ edit: (inout TripDocument) -> Void) async throws {
        guard let trip else { return }
        var document = trip.document
        edit(&document)
        do {
            self.trip = try await api.saveTrip(id: id, document: document, revision: trip.revision)
        } catch let error as SummaryAPIError where error.isTripRevisionConflict {
            // Someone else saved first: reapply this edit (it targets records by id) on their version.
            let fresh = try await api.trip(id: id)
            var merged = fresh.document
            edit(&merged)
            self.trip = try await api.saveTrip(id: id, document: merged, revision: fresh.revision)
            show(.reloaded)
        }
        savedCount += 1
        // Saving re-syncs the tracked flights on the backend.
        Task { await loadFlights() }
    }

    func delete() async throws {
        notice = .deleting
        defer { if notice == .deleting { notice = nil } }
        try await api.deleteTrip(id: id)
    }

    /// Designs a new illustrated cover for the trip's library card; returns the updated card.
    func generateCover() async throws -> Summary {
        notice = .generatingCover
        do {
            let summary = try await api.regenerateImage(id: id, style: .illustration)
            show(.coverUpdated)
            return summary
        } catch {
            notice = nil
            throw error
        }
    }

    /// The trip agent saved an edit from its chat: reload so the diary shows it.
    func agentDidEdit() async {
        guard let fresh = try? await api.trip(id: id) else { return }
        trip = fresh
        savedCount += 1
        show(.agentDone)
        await loadFlights()
    }

    /// Adds or updates the trip's events in the user's calendar.
    func syncCalendar(quietly: Bool = false) async throws {
        guard let document else { return }
        if !quietly { notice = .syncingCalendar }
        do {
            try await TripCalendarSync.shared.sync(document, tripID: id)
            if !quietly { show(.calendarSynced) }
        } catch {
            if notice == .syncingCalendar { notice = nil }
            throw error
        }
    }

    func removeFromCalendar() async throws {
        notice = .syncingCalendar
        do {
            try await TripCalendarSync.shared.remove(tripID: id)
            show(.calendarRemoved)
        } catch {
            notice = nil
            throw error
        }
    }

    /// Refreshes after a push or returning to the app; tells the user when the trip changed.
    func refresh() async {
        guard let current = trip, let fresh = try? await api.trip(id: id) else { return }
        if fresh.revision != current.revision {
            trip = fresh
            show(.reloaded)
        }
        await loadFlights()
    }

    /// Reads the flights the backend tracks for the trip. A just-saved flight is `pending` for a
    /// few seconds while the backend fetches it, so look again shortly.
    func loadFlights() async {
        guard let flights = try? await api.tripFlights(tripId: id) else { return }
        self.flights = flights
        #if os(iOS)
        if trip?.isOwner == true { FlightLiveActivities.shared.startIfDue(flights, tripId: id) }
        #endif
        pendingFlightsTask?.cancel()
        guard flights.contains(where: { $0.state == .pending }) else { return }
        pendingFlightsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            guard let flights = try? await self.api.tripFlights(tripId: self.id) else { return }
            self.flights = flights
        }
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

extension AppEnvironment {
    /// A just-created trip's library item, added to the library so it can be pushed and listed.
    func libraryItem(forCreated trip: Trip) async -> Summary? {
        guard let summary = try? await api.summary(id: trip.id) else {
            await library.reload()
            return nil
        }
        library.insert(summary)
        return summary
    }
}
