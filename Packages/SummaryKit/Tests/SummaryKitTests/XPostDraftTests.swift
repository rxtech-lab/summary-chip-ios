import Foundation
import Testing
@testable import SummaryKit

struct XPostDraftTests {
    private func chip(_ id: String, extra: String = "") throws -> Summary {
        let json = #"{"id":"\#(id)","slug":"\#(id)","shareUrl":"https://example.com/s/\#(id)","title":"Chip","createdAt":"2026-10-28T00:00:00Z"\#(extra)}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Summary.self, from: Data(json.utf8))
    }

    @Test func preservesUnicodeAndReservedCharactersInComposer() throws {
        let source = try chip("a", extra: #","sourceUrl":"https://example.org/story?a=1&b=2#part""#)
        let draft = XPostDraft(title: "中文 & Swift + X #news", summary: "A\n B", sources: [source])
        let url = try #require(URLComponents(url: draft.url, resolvingAgainstBaseURL: false))
        #expect(url.host == "x.com")
        #expect(url.path == "/intent/tweet")
        #expect(url.queryItems == [URLQueryItem(name: "text", value: draft.text)])
        #expect(draft.text == "中文 & Swift + X #news\n\nA B\n\nhttps://example.org/story?a=1&b=2#part")
    }

    @Test func keepsPodcastSourceOrderAndDeduplicatesURLs() throws {
        let first = try chip("a", extra: #","sourceUrl":"https://example.org/first""#)
        let second = try chip("b", extra: #","sourceUrl":"https://example.org/second""#)
        let draft = XPostDraft(title: "Episode", summary: "Overview", sources: [first, second, first])
        #expect(draft.text == "Episode\n\nOverview\n\nhttps://example.org/first\n\nhttps://example.org/second")
    }

    @Test func omitsPrivateAndExpiredFallbackLinks() throws {
        let privateChip = try chip("private", extra: #","visibility":"private""#)
        var expired = try chip("expired", extra: #","visibility":"public""#)
        expired.isExpired = true
        let publicChip = try chip("public", extra: #","visibility":"public""#)
        let draft = XPostDraft(title: "Episode", summary: "", sources: [privateChip, expired, publicChip])
        #expect(draft.text == "Episode\n\nhttps://example.com/s/public")
    }

    @Test func rejectsNonWebSourceAndPreservesFullOverview() throws {
        let source = try chip("a", extra: #","sourceUrl":"file:///secret.txt""#)
        let draft = XPostDraft(title: "Chip", summary: String(repeating: "中", count: 200), sources: [source])
        #expect(draft.text == "Chip\n\n" + String(repeating: "中", count: 200))
        let components = try #require(URLComponents(url: draft.url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first?.value == draft.text)
    }
}
