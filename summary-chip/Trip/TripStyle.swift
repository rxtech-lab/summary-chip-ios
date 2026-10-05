import SummaryKit
import SwiftUI

/// Route colours and line styles from the Northbound diary, plus display names for trip enums.
enum TripStyle {
    static func color(for kind: TripRouteKind?) -> Color {
        switch kind ?? .out {
        case .out, .stay: Color(red: 0xF1 / 255, green: 0x80 / 255, blue: 0x59 / 255)
        case .side: Color(red: 0xE2 / 255, green: 0xC3 / 255, blue: 0x66 / 255)
        case .back: Color(red: 0x66 / 255, green: 0xD6 / 255, blue: 0xD6 / 255)
        case .ferry: Color(red: 0xC5 / 255, green: 0xAB / 255, blue: 0xEF / 255)
        case .airport: Color(red: 0xA5 / 255, green: 0xC8 / 255, blue: 0xEE / 255)
        }
    }

    /// Back legs dashed, ferries dotted, airport transfers short-dashed; `returning` dashes the way back of a round trip.
    static func stroke(for kind: TripRouteKind?, width: CGFloat? = nil, returning: Bool = false) -> StrokeStyle {
        let kind = kind ?? .out
        let dash: [CGFloat] = switch kind {
        case .back: [10, 9]
        case .ferry: [2, 8]
        case .airport: [4, 6]
        default: returning ? [6, 7] : []
        }
        return StrokeStyle(lineWidth: width ?? (kind == .back ? 4 : 5), lineCap: .round, lineJoin: .round, dash: dash)
    }

    static let traveler = Color(red: 0.2, green: 0.25, blue: 0.35)
}

extension TripRouteKind {
    var title: String {
        switch self {
        case .out: String(localized: "Onward", comment: "Trip route kind: travelling on to a new place")
        case .side: String(localized: "Side trip", comment: "Trip route kind")
        case .back: String(localized: "Return", comment: "Trip route kind: heading back")
        case .ferry: String(localized: "Ferry", comment: "Trip route kind")
        case .airport: String(localized: "Airport", comment: "Trip route kind: to or from the airport")
        case .stay: String(localized: "Stay", comment: "Trip route kind: staying in one place")
        }
    }
}

extension TripPlaceKind {
    var title: String {
        switch self {
        case .city: String(localized: "City")
        case .station: String(localized: "Station")
        case .airport: String(localized: "Airport")
        case .hotel: String(localized: "Hotel")
        case .poi: String(localized: "Point of interest")
        case .port: String(localized: "Port")
        }
    }

    var systemImage: String {
        switch self {
        case .city: "building.2"
        case .station: "tram"
        case .airport: "airplane"
        case .hotel: "bed.double"
        case .poi: "mappin"
        case .port: "ferry"
        }
    }
}

extension TripMomentSlot {
    var title: String {
        switch self {
        case .morning: String(localized: "Morning")
        case .afternoon: String(localized: "Afternoon")
        case .evening: String(localized: "Evening")
        case .night: String(localized: "Night")
        }
    }
}

extension TripBookingStatus {
    var title: String {
        switch self {
        case .idea: String(localized: "Idea", comment: "Booking status: not planned yet")
        case .planned: String(localized: "Planned", comment: "Booking status")
        case .booked: String(localized: "Booked", comment: "Booking status")
        }
    }

    var tint: Color {
        switch self {
        case .idea: .secondary
        case .planned: .orange
        case .booked: .green
        }
    }
}

extension TripSegmentMode {
    var title: String {
        switch self {
        case .train: String(localized: "Train")
        case .flight: String(localized: "Flight")
        case .ferry: String(localized: "Ferry")
        case .bus: String(localized: "Bus")
        case .car: String(localized: "Car")
        case .walk: String(localized: "Walk")
        case .other: String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .train: "tram.fill"
        case .flight: "airplane"
        case .ferry: "ferry.fill"
        case .bus: "bus.fill"
        case .car: "car.fill"
        case .walk: "figure.walk"
        case .other: "arrow.triangle.swap"
        }
    }
}

extension TripTrainCategory {
    var title: String {
        switch self {
        case .shinkansen: String(localized: "Shinkansen")
        case .limitedExpress: String(localized: "Limited express")
        case .rapid: String(localized: "Rapid")
        case .local: String(localized: "Local", comment: "Train category: stops at every station")
        case .other: String(localized: "Other")
        }
    }
}

extension TripSeatClass {
    var title: String {
        switch self {
        case .reserved: String(localized: "Reserved")
        case .nonReserved: String(localized: "Non-reserved")
        case .green: String(localized: "Green Car")
        case .granClass: String(localized: "GranClass")
        case .economy: String(localized: "Economy")
        case .premiumEconomy: String(localized: "Premium economy")
        case .business: String(localized: "Business")
        case .first: String(localized: "First")
        }
    }
}

extension TripExpenseCategory {
    var title: String {
        switch self {
        case .transport: String(localized: "Transport")
        case .lodging: String(localized: "Lodging")
        case .food: String(localized: "Food")
        case .activity: String(localized: "Activity")
        case .shopping: String(localized: "Shopping")
        case .pass: String(localized: "Pass", comment: "Expense category: a rail pass or bundle that covers other costs")
        case .other: String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .transport: "tram"
        case .lodging: "bed.double"
        case .food: "fork.knife"
        case .activity: "ticket"
        case .shopping: "bag"
        case .pass: "wallet.pass"
        case .other: "ellipsis.circle"
        }
    }
}

extension TripDocument {
    /// "Oct 10 – 20, 2026", in the trip's time zone.
    var dateRangeText: String {
        let zone = resolvedTimeZone
        guard let start = TripDate.date(from: startDate, timeZone: zone), let end = TripDate.date(from: endDate, timeZone: zone) else {
            return "\(startDate) – \(endDate)"
        }
        var style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = zone
        return (start..<max(start, end)).formatted(style)
    }

    /// "Sat, Oct 10" for a `YYYY-MM-DD` day.
    func dayLabel(_ date: String) -> String {
        let zone = resolvedTimeZone
        guard let day = TripDate.date(from: date, timeZone: zone) else { return date }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted).weekday(.abbreviated)
        style.timeZone = zone
        return day.formatted(style)
    }
}

extension String {
    /// Nil for empty or whitespace-only text, for optional document fields.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
