import Foundation

public enum TTLFormatter {
    /// "1 day", "3 days", "1 week", "1 month", "3 months", "1 year", "Never".
    public static func optionTitle(_ option: TTLOption) -> String {
        switch option {
        case .never: return "Never"
        case .days(let days):
            switch days {
            case 7: return "1 week"
            case 30: return "1 month"
            case 90: return "3 months"
            case 365: return "1 year"
            case 1: return "1 day"
            default: return "\(days) days"
            }
        }
    }

    /// Compact link countdown: "Expires in 3d", "Expires in 5h", "Expires in 12m", "Link expired", "No expiry".
    public static func countdown(until expiresAt: Date?, now: Date = Date()) -> String {
        guard let expiresAt else { return "No expiry" }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Link expired" }
        let minutes = Int(remaining / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return "Expires in \(days)d" }
        if hours >= 1 { return "Expires in \(hours)h" }
        return "Expires in \(max(1, minutes))m"
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
            if age < 60 { return "Just now" }
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
        case .yesterday: return "Yesterday"
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
