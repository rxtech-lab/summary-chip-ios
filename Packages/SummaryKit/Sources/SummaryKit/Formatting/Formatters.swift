import Foundation

public enum TTLFormatter {
    /// "1 day", "3 days", "1 week", "1 month", "3 months", "1 year", "Never".
    public static func optionTitle(_ option: TTLOption) -> String {
        switch option {
        case .never: return String(localized: "Never", bundle: .module, comment: "Link lifetime option: never expires")
        case .days(let days):
            switch days {
            case 7: return String(localized: "1 week", bundle: .module)
            case 30: return String(localized: "1 month", bundle: .module)
            case 90: return String(localized: "3 months", bundle: .module)
            case 365: return String(localized: "1 year", bundle: .module)
            case 1: return String(localized: "1 day", bundle: .module)
            default: return String(localized: "\(days) days", bundle: .module)
            }
        }
    }

    /// Compact link countdown: "Expires in 3d", "Expires in 5h", "Expires in 12m", "Link expired", "No expiry".
    public static func countdown(until expiresAt: Date?, now: Date = Date()) -> String {
        guard let expiresAt else { return String(localized: "No expiry", bundle: .module) }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return String(localized: "Link expired", bundle: .module) }
        let minutes = Int(remaining / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return String(localized: "Expires in \(days)d", bundle: .module, comment: "Compact countdown in days") }
        if hours >= 1 { return String(localized: "Expires in \(hours)h", bundle: .module, comment: "Compact countdown in hours") }
        return String(localized: "Expires in \(max(1, minutes))m", bundle: .module, comment: "Compact countdown in minutes")
    }

    /// True when less than a day remains (used to tint the countdown).
    public static func isExpiringSoon(_ expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        let remaining = expiresAt.timeIntervalSince(now)
        return remaining > 0 && remaining < 86_400
    }
}

/// Buckets used for the Library / History section headers.
public enum DateSection: String, CaseIterable, Sendable, Identifiable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This Week"
    case earlier = "Earlier"

    public var id: String { rawValue }

    /// Localized header text; `rawValue` stays the stable English identifier.
    public var title: String {
        switch self {
        case .today: String(localized: "Today", bundle: .module)
        case .yesterday: String(localized: "Yesterday", bundle: .module)
        case .thisWeek: String(localized: "This Week", bundle: .module)
        case .earlier: String(localized: "Earlier", bundle: .module)
        }
    }

    public static func section(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> DateSection {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return .thisWeek
        }
        return .earlier
    }

    /// Groups already-sorted items, preserving order within each bucket.
    public static func group<T>(_ items: [T], now: Date = Date(), calendar: Calendar = .current, date: (T) -> Date) -> [(section: DateSection, items: [T])] {
        var buckets: [DateSection: [T]] = [:]
        for item in items { buckets[section(for: date(item), now: now, calendar: calendar), default: []].append(item) }
        return DateSection.allCases.compactMap { section in
            guard let items = buckets[section], !items.isEmpty else { return nil }
            return (section, items)
        }
    }
}

public enum SummaryDateFormatter {
    /// "2 days ago" for the last week, "Sep 30, 2026" otherwise.
    public static func display(_ date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        if age >= 0 && age < 7 * 86_400 {
            if age < 60 { return String(localized: "Just now", bundle: .module) }
            return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Feed-tile stamp: "9:41 AM" today, "Yesterday", "Monday" this week, "Sep 30" this
    /// year, "Sep 30, 2025" otherwise.
    public static func tile(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.timeZone = calendar.timeZone
        switch DateSection.section(for: date, now: now, calendar: calendar) {
        case .today: return date.formatted(time)
        case .yesterday: return String(localized: "Yesterday", bundle: .module)
        case .thisWeek:
            var weekday = Date.FormatStyle().weekday(.wide)
            weekday.timeZone = calendar.timeZone
            return date.formatted(weekday)
        case .earlier:
            var style = calendar.isDate(date, equalTo: now, toGranularity: .year)
                ? Date.FormatStyle().month(.abbreviated).day()
                : Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
    }
}
