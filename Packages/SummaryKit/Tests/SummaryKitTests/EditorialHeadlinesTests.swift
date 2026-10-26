import Foundation
import Testing
@testable import SummaryKit

struct EditorialHeadlinesTests {
    @Test func decodesPersistedPicksWhileRankingIsPending() throws {
        let data = Data(#"{"generatedAt":null,"pending":true,"items":[],"highlighted":null,"editorPickIDs":["today-a","today-b","yesterday"]}"#.utf8)
        let result = try JSONDecoder().decode(EditorialHeadlines.self, from: data)
        #expect(result.pending)
        #expect(result.editorPickIDs == ["today-a", "today-b", "yesterday"])
    }

    @Test func decodesOlderServerWithoutPersistedPicks() throws {
        let data = Data(#"{"generatedAt":null,"pending":false,"items":[],"highlighted":null}"#.utf8)
        let result = try JSONDecoder().decode(EditorialHeadlines.self, from: data)
        #expect(result.editorPickIDs == nil)
    }
}
