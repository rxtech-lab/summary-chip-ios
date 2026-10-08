import Foundation
import SummaryKit

/// Formats the day caption in the app's language and the trip's time zone.
enum TripTourFacts {
    /// "Sat, Oct 10".
    static func dayText(_ date: String, in document: TripDocument) -> String {
        let zone = TimeZone(identifier: document.timeZone) ?? .current
        guard let value = TripDate.date(from: date, timeZone: zone) else { return date }
        return value.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: zone).weekday(.abbreviated))
    }

}
