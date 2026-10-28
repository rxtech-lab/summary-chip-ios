import Foundation
import Testing
@testable import SummaryKit

struct PodcastStackTests {
    private func summary(_ id: String, kind: String = "summary", extra: String = "") throws -> Summary {
        let json = #"{"id":"\#(id)","kind":"\#(kind)","slug":"\#(id)","shareUrl":"https://example.com/s/\#(id)","title":"\#(id)","createdAt":"2026-10-28T00:00:00Z"\#(extra)}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Summary.self, from: Data(json.utf8))
    }

    @Test func decodesStackLinks() throws {
        #expect(try summary("p", kind: "podcast", extra: #","podcastSourceId":"c""#).podcastSourceId == "c")
        #expect(try summary("c", extra: #","stackedPodcastId":"p""#).stackedPodcastId == "p")
        #expect(try summary("old").stackedPodcastId == nil)
    }

    @Test func foldsSoloPodcastIntoItsListedChip() throws {
        let entries = try [
            summary("solo", kind: "podcast", extra: #","podcastSourceId":"chip""#),
            summary("elsewhere", kind: "podcast", extra: #","podcastSourceId":"missing""#),
            summary("multi", kind: "podcast"),
            summary("chip"),
            summary("linked", extra: #","stackedPodcastId":"unlisted""#),
        ].map(SummaryFeedEntry.init(summary:))
        let stacked = SummaryFeedEntry.stackingPodcasts(entries)
        #expect(stacked.map(\.id) == ["elsewhere", "multi", "chip", "linked"])
        #expect(stacked.first { $0.id == "chip" }?.stackedPodcastID == "solo")
        #expect(stacked.first { $0.id == "linked" }?.stackedPodcastID == "unlisted")
        #expect(stacked.first { $0.id == "multi" }?.stackedPodcastID == nil)
    }
}
