import Foundation
import Testing
@testable import SummaryKit

struct EditorialWidgetSelectionTests {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func headline(_ id: String, date: Date, score: Int = 90) -> EditorialHeadline {
        EditorialHeadline(id: id, title: id, kind: .summary,
                          shareUrl: URL(string: "https://example.com/s/\(id)")!, createdAt: date, score: score)
    }

    @Test func keepsLatestPickDayAndRankingOrder() {
        let older = headline("older", date: day.addingTimeInterval(-86400))
        let first = headline("first", date: day)
        let second = headline("second", date: day.addingTimeInterval(60))
        let low = headline("low", date: day.addingTimeInterval(86400), score: 40)
        let result = EditorialHeadlines(generatedAt: day, pending: false,
                                       items: [older, first, second, low], highlighted: older,
                                       editorPickIDs: ["older", "first", "second"])
        #expect(result.widgetPicks().map(\.id) == ["first", "second"])
        #expect(result.widgetPicks(limit: 1).map(\.id) == ["first"])
        #expect(result.widgetPicks(limit: 0).isEmpty)
    }

    @Test func groupsUsingLocalCalendarAndDeduplicates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let midnight = calendar.startOfDay(for: day)
        let previous = headline("previous", date: midnight.addingTimeInterval(-1))
        let latest = headline("latest", date: midnight.addingTimeInterval(1))
        let result = EditorialHeadlines(generatedAt: day, pending: false,
                                       items: [previous, latest, latest], highlighted: latest, editorPickIDs: nil)
        #expect(result.widgetPicks(calendar: calendar).map(\.id) == ["latest"])
    }

    @Test func legacyScoresUseSeventyPointThreshold() {
        let below = headline("below", date: day, score: 69)
        let boundary = headline("boundary", date: day, score: 70)
        let above = headline("above", date: day, score: 79)
        let result = EditorialHeadlines(generatedAt: day, pending: false,
                                       items: [above, boundary, below], highlighted: above, editorPickIDs: nil)
        #expect(result.widgetPicks().map(\.id) == ["above", "boundary"])
    }

    @Test func emptyWhenNoPicksOrRankingPending() {
        let low = headline("low", date: day, score: 69)
        let result = EditorialHeadlines(generatedAt: day, pending: false,
                                       items: [low], highlighted: low, editorPickIDs: nil)
        #expect(result.widgetPicks().isEmpty)
        let pending = EditorialHeadlines(generatedAt: nil, pending: true,
                                        items: [], highlighted: nil, editorPickIDs: ["saved"])
        #expect(pending.widgetPicks().isEmpty)
    }
}
