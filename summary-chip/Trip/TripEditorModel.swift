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
        case switchingLanguage
        case languageChanged
        case translatingInBackground

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
            case .switchingLanguage: String(localized: "Switching language…")
            case .languageChanged: String(localized: "Language changed")
            case .translatingInBackground: String(localized: "Translating — we'll notify you")
            }
        }

        var systemImage: String {
            switch self {
            case .reloaded: "arrow.triangle.2.circlepath"
            case .deleting, .generatingCover, .syncingCalendar, .switchingLanguage: "hourglass"
            case .coverUpdated, .agentDone, .calendarSynced, .calendarRemoved: "checkmark.circle"
            case .languageChanged: "translate"
            case .translatingInBackground: "hourglass"
            }
        }

        var isWorking: Bool { [.deleting, .generatingCover, .syncingCalendar, .switchingLanguage].contains(self) }
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
    /// The trip's forecasts per day, as the backend last stored them.
    private(set) var weather: TripWeather = .empty
    /// When the user starred the trip (it's under Likes). Only reads carry it, so saves keep it as is.
    var likedAt: Date?
    /// The plan options the user follows (plan id → option id). Only reads carry them, so saves keep them as is.
    private(set) var planSelections: [String: String] = [:]
    /// The trip as the user follows it: only the picked plan options' days, stays, transport and costs.
    private(set) var displayDocument: TripDocument?

    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFlightsTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWeatherTask: Task<Void, Never>?

    init(api: SummaryAPIClient, id: String) {
        self.api = api
        self.id = id
    }

    /// The trip as written, every plan option included: what edits apply to.
    var document: TripDocument? { trip?.document }

    /// Sets the trip (and the user's picks, when the response carries them) and refreshes what's shown.
    private func apply(_ trip: Trip) {
        self.trip = trip
        if let selections = trip.planSelections { planSelections = selections }
        displayDocument = trip.document.following(planSelections)
    }

    /// Follows another option of a plan at once and returns the save of the pick for the user; when
    /// saving fails the pick is undone and the task throws.
    @discardableResult
    func selectPlanOption(planID: String, optionID: String) -> Task<Void, any Error> {
        let previous = planSelections[planID]
        follow(planSelections.merging([planID: optionID]) { $1 })
        return Task {
            do {
                let saved = try await api.selectTripPlanOption(tripId: id, planId: planID, optionId: optionID)
                // A later pick of the same plan wins over this response.
                if planSelections[planID] == optionID { follow(saved) }
            } catch {
                if planSelections[planID] == optionID {
                    var reverted = planSelections
                    reverted[planID] = previous
                    follow(reverted)
                }
                throw error
            }
        }
    }

    private func follow(_ selections: [String: String]) {
        planSelections = selections
        if let trip { displayDocument = trip.document.following(selections) }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await api.trip(id: id)
            apply(fresh)
            likedAt = fresh.likedAt
            loadError = nil
            await loadFlights()
            await loadWeather()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if trip == nil { loadError = error.localizedDescription }
        }
    }

    /// Applies `edit` to the current document and saves it. Throws when the save fails; the
    /// caller's sheet stays open to show the error.
    func update(_ edit: (inout TripDocument) -> Void) async throws {
        // A translation is never saved over the trip as written.
        guard let trip, !trip.isTranslated else { return }
        var document = trip.document
        edit(&document)
        do {
            apply(try await api.saveTrip(id: id, document: document, revision: trip.revision))
        } catch let error as SummaryAPIError where error.isTripRevisionConflict {
            // Someone else saved first: reapply this edit (it targets records by id) on their version.
            let fresh = try await api.trip(id: id)
            // Switched to a translation on another device meanwhile: show it, but don't save over it.
            guard !fresh.isTranslated else {
                apply(fresh)
                throw error
            }
            var merged = fresh.document
            edit(&merged)
            apply(try await api.saveTrip(id: id, document: merged, revision: fresh.revision))
            show(.reloaded)
        }
        savedCount += 1
        // Saving re-syncs the tracked flights and the forecast's places on the backend.
        Task { await loadFlights() }
        Task { await loadWeather() }
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
        apply(fresh)
        savedCount += 1
        show(.agentDone)
        await loadFlights()
        await loadWeather()
    }

    /// Adds or updates the trip's events in the user's calendar.
    func syncCalendar(quietly: Bool = false) async throws {
        // Only the options the user follows go in the calendar.
        guard let document = displayDocument else { return }
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

    /// The owner picked another reading language: show the diary in it. A large trip is still being
    /// translated in the background; it shows as written until the "Trip translated" push.
    func languageChanged() async {
        notice = .switchingLanguage
        guard let fresh = try? await api.trip(id: id) else {
            notice = nil
            return
        }
        apply(fresh)
        likedAt = fresh.likedAt
        show(fresh.translating ? .translatingInBackground : .languageChanged)
    }

    /// Refreshes after a push or returning to the app; tells the user when the trip changed.
    func refresh() async {
        guard let current = trip, let fresh = try? await api.trip(id: id) else { return }
        likedAt = fresh.likedAt
        if fresh.revision != current.revision {
            apply(fresh)
            show(.reloaded)
        } else if fresh.language != current.language || fresh.translating != current.translating {
            // A background translation finished (or another device switched the language).
            apply(fresh)
            show(.languageChanged)
        } else if let selections = fresh.planSelections, selections != planSelections {
            // Picked another option on another device.
            apply(fresh)
        }
        await loadFlights()
        await loadWeather()
    }

    /// Reads the forecasts the backend keeps for the trip (it refreshes them and sends the
    /// weather alerts). A just-added place is fetched within seconds of the save, so look again shortly.
    func loadWeather() async {
        guard let weather = try? await api.tripWeather(tripId: id) else { return }
        self.weather = weather
        pendingWeatherTask?.cancel()
        let waiting = weather.days.contains { day in
            day.locations.contains { $0.forecast == nil } && TripWeatherWindow.isForecastable(day.date)
        }
        guard waiting else { return }
        pendingWeatherTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            guard let weather = try? await self.api.tripWeather(tripId: self.id) else { return }
            self.weather = weather
        }
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
