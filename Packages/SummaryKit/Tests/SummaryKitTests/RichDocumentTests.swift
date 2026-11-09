import Foundation
import Testing
@testable import SummaryKit

@Suite struct RichDocumentModelTests {
    @Test func decodesTheServerShapeWithDefaults() throws {
        let json = #"""
        {"id":"d","slug":"abc","revision":2,"visibility":"public","isOwner":false,"createdAt":"2026-11-09T00:00:00.000Z","updatedAt":"2026-11-09T00:00:00.000Z","shareUrl":"https://example.com/s/abc",
         "document":{"version":1,"title":"Notes","description":null,"blocks":[
           {"id":"b1","type":"text","columns":[{"markdown":"## Hi"},{"markdown":"There"}]},
           {"id":"b2","type":"video","align":"center","columns":[{"url":"https://x.com/a.mp4","posterUrl":"https://x.com/a.jpg","caption":"Dawn"}],
            "children":[{"type":"link","title":"Source","url":"https://x.com"},{"type":"button","title":"Later"}]},
           {"id":"b3","type":"map","align":"sideways","columns":[{}]}
         ]}}
        """#
        let document = try SummaryJSON.decoder().decode(RichDocument.self, from: Data(json.utf8))
        #expect(document.revision == 2)
        #expect(!document.isOwner)
        let blocks = document.document.blocks
        #expect(blocks[0].align == .leading)
        #expect(blocks[0].columns.count == 2)
        #expect(blocks[0].children.isEmpty)
        #expect(blocks[1].type == .video)
        #expect(blocks[1].align == .center)
        #expect(blocks[1].columns[0].posterUrl?.absoluteString == "https://x.com/a.jpg")
        #expect(blocks[1].children.compactMap(\.link).map(\.title) == ["Source"])
        // A newer server's block type and alignment still decode.
        #expect(blocks[2].type == .other("map"))
        #expect(blocks[2].align == .leading)
    }

    @Test func knowsTheKind() throws {
        #expect(SummaryKind(rawValue: "rich_document") == .richDocument)
        #expect(SummaryKind.richDocument.rawValue == "rich_document")
        #expect(SummaryKind.known.contains(.richDocument))
        let version = #"""
        {"version":1,"kind":"rich_document","actor":"agent","title":"Notes","createdAt":"2026-11-09T00:00:00.000Z","isCurrent":true,
         "content":{"version":1,"title":"Notes","blocks":[{"id":"b1","type":"text","columns":[{"markdown":"Hi"}]}]}}
        """#
        let detail = try SummaryJSON.decoder().decode(DocumentVersionDetail.self, from: Data(version.utf8))
        guard case .richDocument(let content) = detail.content else {
            Issue.record("expected rich document content")
            return
        }
        #expect(content.blocks.first?.id == "b1")
    }
}
