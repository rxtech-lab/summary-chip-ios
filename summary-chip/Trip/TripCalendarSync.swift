import EventKit
import Foundation
import SummaryKit

/// Copies a trip into the user's default calendar: one all-day event for the whole trip, one per
/// hotel stay and one per transport (timed when it has times). Later syncs update or remove those
/// same events instead of adding copies; which event belongs to which trip record is remembered on
/// this device.
final class TripCalendarSync {
    enum SyncError: LocalizedError {
        case denied
        case noCalendar

        var errorDescription: String? {
            switch self {
            case .denied: String(localized: "Chippy can't use your calendar. Allow full calendar access for Chippy in Settings.")
            case .noCalendar: String(localized: "There is no calendar to add events to.")
            }
        }
    }

    static let shared = TripCalendarSync()

    private let store = EKEventStore()

    /// Whether this trip has events on this device's calendar.
    func isSynced(tripID: String) -> Bool {
        !links(tripID).isEmpty
    }

    /// Adds or updates the trip's events and removes the ones whose records are gone. Returns how
    /// many events the trip now has.
    @discardableResult
    func sync(_ document: TripDocument, tripID: String) async throws -> Int {
        try await requestAccess()
        guard let calendar = store.defaultCalendarForNewEvents else { throw SyncError.noCalendar }
        let previous = links(tripID)
        var current: [String: String] = [:]
        for draft in Self.drafts(for: document) {
            let event = previous[draft.key].flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
            if event.calendar == nil { event.calendar = calendar }
            draft.apply(to: event)
            try store.save(event, span: .thisEvent)
            if let identifier = event.eventIdentifier { current[draft.key] = identifier }
        }
        for (key, identifier) in previous where current[key] == nil {
            if let event = store.event(withIdentifier: identifier) { try store.remove(event, span: .thisEvent) }
        }
        setLinks(current, for: tripID)
        return current.count
    }

    /// Deletes every event this device added for the trip.
    func remove(tripID: String) async throws {
        try await requestAccess()
        for identifier in links(tripID).values {
            if let event = store.event(withIdentifier: identifier) { try store.remove(event, span: .thisEvent) }
        }
        setLinks([:], for: tripID)
    }

    private func requestAccess() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        guard try await store.requestFullAccessToEvents() else { throw SyncError.denied }
    }

    // MARK: Links

    private func key(_ tripID: String) -> String { "trip-calendar-links.\(tripID)" }

    private func links(_ tripID: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key(tripID)) as? [String: String] ?? [:]
    }

    private func setLinks(_ links: [String: String], for tripID: String) {
        if links.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(tripID))
        } else {
            UserDefaults.standard.set(links, forKey: key(tripID))
        }
    }

    // MARK: Events

    /// One calendar event to write, keyed by the trip record it comes from.
    struct Draft: Equatable {
        var key: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var timeZone: TimeZone
        var location: String?
        var notes: String?

        func apply(to event: EKEvent) {
            event.title = title
            event.isAllDay = isAllDay
            event.timeZone = isAllDay ? nil : timeZone
            event.startDate = start
            event.endDate = end
            event.location = location
            event.notes = notes
        }
    }

    static func drafts(for document: TripDocument) -> [Draft] {
        let zone = document.resolvedTimeZone
        var drafts: [Draft] = []
        if let start = TripDate.date(from: document.startDate, timeZone: zone) {
            let end = TripDate.date(from: document.endDate, timeZone: zone) ?? start
            drafts.append(Draft(key: "trip", title: document.title, start: start, end: max(start, end), isAllDay: true, timeZone: zone, location: nil, notes: document.subtitle))
        }
        for hotel in document.hotels {
            guard let checkIn = TripDate.date(from: hotel.checkIn, timeZone: zone) else { continue }
            let checkOut = TripDate.date(from: hotel.checkOut, timeZone: zone) ?? checkIn
            let notes = hotel.confirmation.map { String(localized: "Confirmation: \($0)") }
            drafts.append(Draft(
                key: "hotel:\(hotel.id)",
                title: String(localized: "Stay at \(hotel.name)"),
                start: checkIn,
                end: max(checkIn, checkOut),
                isAllDay: true,
                timeZone: zone,
                location: hotel.address ?? hotel.name,
                notes: notes
            ))
        }
        for transport in document.transports {
            let option = transport.selectedOption
            let notes = option?.segments.map { "\($0.fromName) → \($0.toName)" }.joined(separator: "\n")
            let location = option?.segments.first?.fromName
            if let departure = option?.effectiveDeparture.flatMap({ localDateTime($0, timeZone: zone) }) {
                let arrival = option?.effectiveArrival.flatMap { localDateTime($0, timeZone: zone) }
                let end = arrival.flatMap { $0 > departure ? $0 : nil } ?? departure.addingTimeInterval(3600)
                drafts.append(Draft(key: "transport:\(transport.id)", title: transport.label, start: departure, end: end, isAllDay: false, timeZone: zone, location: location, notes: notes))
            } else if let day = TripDate.date(from: transport.date, timeZone: zone) {
                drafts.append(Draft(key: "transport:\(transport.id)", title: transport.label, start: day, end: day, isAllDay: true, timeZone: zone, location: location, notes: notes))
            }
        }
        return drafts
    }

    /// A `YYYY-MM-DDTHH:mm` local time in the trip's zone.
    static func localDateTime(_ value: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: String(value.prefix(16)))
    }
}
