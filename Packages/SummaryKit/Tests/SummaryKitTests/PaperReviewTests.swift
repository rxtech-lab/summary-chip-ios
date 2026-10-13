import Foundation
import Testing
@testable import SummaryKit

@Suite struct PaperReviewTests {
    private static let reviewsJSON = #"""
        {"reviews":[
          {"id":"r1","paperId":"p1","file":"intro.tex","quote":"turn slowly","comment":"Add a number.","status":"open","version":2,
           "addressedVersion":null,"agentNote":null,"createdAt":"2026-10-12T08:00:00.000Z","updatedAt":"2026-10-12T08:00:00.000Z","addressedAt":null,"resolvedAt":null},
          {"id":"r2","paperId":"p1","file":null,"quote":"Gears","comment":"Rename.","status":"addressed","version":2,
           "addressedVersion":3,"agentNote":"Renamed to Cogs.","createdAt":"2026-10-12T08:01:00.000Z","updatedAt":"2026-10-12T08:05:00.000Z","addressedAt":"2026-10-12T08:05:00.000Z","resolvedAt":null},
          {"id":"r3","paperId":"p1","file":null,"quote":"x","comment":"y","status":"archived","version":1,
           "addressedVersion":null,"agentNote":null,"createdAt":"2026-10-12T08:01:00.000Z","updatedAt":"2026-10-12T08:05:00.000Z","addressedAt":null,"resolvedAt":null}
        ]}
        """#

    private struct Envelope: Decodable { let reviews: [PaperReview] }

    @Test func decodesReviews() throws {
        let reviews = try SummaryJSON.decoder().decode(Envelope.self, from: Data(Self.reviewsJSON.utf8)).reviews
        #expect(reviews.map(\.status) == [.open, .addressed, .open])
        #expect(reviews[0].file == "intro.tex")
        #expect(!reviews[0].hasChanges)
        #expect(reviews[1].hasChanges)
        #expect(reviews[1].agentNote == "Renamed to Cogs.")
        #expect(reviews[1].addressedAt != nil)
        #expect(reviews.filter(\.isUnresolved).count == 3)
    }

    @Test func encodesADraftWithoutAnEmptyFile() throws {
        let data = try JSONEncoder().encode(PaperReviewDraft(quote: "q", comment: "c"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["quote"] as? String == "q")
        #expect(object["file"] == nil)
    }

    @Test func diffsChangedLinesWithContext() {
        let old = PaperSource(title: "T", files: [
            PaperFile(path: "main.tex", content: "a\nb\nc\nd\ne\nf\ng\nh\n"),
            PaperFile(path: "gone.tex", content: "bye\n"),
            PaperFile(path: "same.bib", content: "@book{k}"),
        ], mainFile: "main.tex")
        let new = PaperSource(title: "T", files: [
            PaperFile(path: "main.tex", content: "a\nb\nC\nd\ne\nf\ng\nh\ni\n"),
            PaperFile(path: "new.tex", content: "hi\nthere\n"),
            PaperFile(path: "same.bib", content: "@book{k}"),
        ], mainFile: "main.tex")
        let diff = PaperDiff(old: old, new: new)
        #expect(diff.files.map(\.path) == ["main.tex", "new.tex", "gone.tex"])
        #expect(diff.files.map(\.change) == [.modified, .added, .removed])
        #expect(diff.added == 4 && diff.removed == 2)
        let main = diff.files[0]
        #expect(main.hunks.count == 2)
        #expect(main.hunks[0].lines.map(\.text) == ["a", "b", "c", "C", "d", "e"])
        #expect(main.hunks[0].lines.map(\.kind) == [.same, .same, .removed, .added, .same, .same])
        #expect(main.hunks[0].lines[2].oldNumber == 3 && main.hunks[0].lines[2].newNumber == nil)
        #expect(main.hunks[0].lines[3].newNumber == 3)
        #expect(main.hunks[1].lines.map(\.text) == ["g", "h", "i"])
        #expect(main.hunks[1].lines.last?.newNumber == 9)
        #expect(diff.files[1].hunks.first?.lines.map(\.kind) == [.added, .added])
        #expect(diff.files[2].hunks.first?.lines.first?.kind == .removed)
        #expect(PaperDiff(old: old, new: old).isEmpty)
    }

    @Test func diffsImagesByTheirAsset() {
        let before = PaperFile(path: "fig.png", asset: PaperAsset(key: "a", mimeType: "image/png", byteSize: 1))
        let after = PaperFile(path: "fig.png", asset: PaperAsset(key: "b", mimeType: "image/png", byteSize: 1))
        let main = PaperFile(path: "main.tex", content: "x")
        let diff = PaperDiff(old: PaperSource(title: "T", files: [main, before], mainFile: "main.tex"), new: PaperSource(title: "T", files: [main, after], mainFile: "main.tex"))
        #expect(diff.files.map(\.path) == ["fig.png"])
        #expect(diff.files[0].isImage && diff.files[0].hunks.isEmpty)
    }

    @Test func readerKeepsDrawingSources() {
        let document = PaperReader.read(PaperSource(title: "T", files: [PaperFile(path: "main.tex", content: #"""
        \begin{document}
        \begin{figure}
        \begin{tikzpicture}[scale=2]\draw (0,0) -- (1,1);\end{tikzpicture}
        \caption{A line.}
        \end{figure}
        \begin{tikzpicture}\node {x};\end{tikzpicture}
        \end{document}
        """#)], mainFile: "main.tex"))
        let figures = document.blocks.compactMap { if case .figure(let figure) = $0.kind { figure } else { nil } }
        #expect(figures.count == 2)
        #expect(figures[0].drawings == 1)
        #expect(figures[0].drawingSources == [#"\begin{tikzpicture}[scale=2]\draw (0,0) -- (1,1);\end{tikzpicture}"#])
        #expect(figures[1].drawingSources == [#"\begin{tikzpicture}\node {x};\end{tikzpicture}"#])
    }
}
