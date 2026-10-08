import Foundation
import Testing
@testable import SummaryKit

@Suite struct DocumentVersionTests {
    @Test func decodesAPageWithUnknownActors() throws {
        let page = try SummaryJSON.decoder().decode(DocumentVersionPage.self, from: Data(#"""
            {"items":[
              {"version":3,"kind":"summary","actor":"restore","restoredFrom":1,"createdAt":"2026-10-09T08:00:00.123Z","title":"Gears","isCurrent":true},
              {"version":2,"kind":"summary","actor":"robot","restoredFrom":null,"createdAt":"2026-10-08T08:00:00Z","title":"Old","isCurrent":false}
            ],"nextCursor":"2"}
            """#.utf8))
        #expect(page.items.map(\.version) == [3, 2])
        #expect(page.items[0].actor == .restore && page.items[0].restoredFrom == 1 && page.items[0].isCurrent)
        #expect(page.items[1].actor == .other("robot"))
        #expect(page.nextCursor == "2")
    }

    @Test func decodesContentByKind() throws {
        let summary = try SummaryJSON.decoder().decode(DocumentVersionDetail.self, from: Data(#"""
            {"version":1,"kind":"summary","actor":"owner","restoredFrom":null,"createdAt":"2026-10-08T08:00:00Z","title":"Gears","isCurrent":false,
             "content":{"title":"Gears","summary":"Entangled.","highlights":["One"],"category":"Science","tags":["physics"],"keywords":[]}}
            """#.utf8))
        guard case .summary(let text) = summary.content else { Issue.record("expected summary content"); return }
        #expect(text.highlights == ["One"] && text.tags == ["physics"])

        let trip = try SummaryJSON.decoder().decode(DocumentVersionDetail.self, from: Data(#"""
            {"version":2,"kind":"trip","actor":"chat","restoredFrom":null,"createdAt":"2026-10-08T08:00:00Z","title":"Lisbon","isCurrent":true,
             "content":{"document":{"title":"Lisbon","startDate":"2026-11-06","endDate":"2026-11-09"}}}
            """#.utf8))
        guard case .trip(let document) = trip.content else { Issue.record("expected trip content"); return }
        #expect(document.title == "Lisbon")
    }

    @Test func showsAVersionAsWritten() throws {
        let summary = try SummaryJSON.decoder().decode(Summary.self, from: fixture("summary.json"))
        let content = SummaryVersionContent(title: "Older title", summary: "Older text.", highlights: ["A"], category: "Other", tags: ["x"], keywords: [])
        let shown = summary.showing(content)
        #expect(shown.title == "Older title" && shown.summary == "Older text." && shown.displayTags == ["x"])
        #expect(shown.id == summary.id && shown.language == summary.originalLanguage)
    }

    @Test func restoreDecodesWithoutAVersion() throws {
        let restored = try SummaryJSON.decoder().decode(DocumentVersionRestore.self, from: Data(#"{"version":null,"summary":null,"trip":null}"#.utf8))
        #expect(restored.version == nil && restored.summary == nil && restored.trip == nil)
    }
}
