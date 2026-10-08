import Foundation
import Testing
@testable import SummaryKit

@Suite struct PaperTests {
    private static let paperJSON = #"""
        {"id":"p1","slug":"a1B2c3D4e5","revision":3,"visibility":"private","isOwner":true,
         "createdAt":"2026-10-09T08:00:00.000Z","updatedAt":"2026-10-09T09:00:00Z","shareUrl":"https://summary.rxlab.app/s/a1B2c3D4e5",
         "title":"Quantum Gears","mainFile":"main.tex","compiler":"futuretex","version":2,"hasUnversionedChanges":true,"likedAt":null,
         "files":[{"path":"references.bib","content":"@misc{}"},{"path":"sections/intro.tex","content":"\\section{Intro}"},{"path":"main.tex","content":"\\documentclass{article}"}]}
        """#

    @Test func decodesAPaper() throws {
        let paper = try SummaryJSON.decoder().decode(Paper.self, from: Data(Self.paperJSON.utf8))
        #expect(paper.revision == 3 && paper.version == 2 && paper.hasUnversionedChanges)
        // An engine this build doesn't know reads as the standard one.
        #expect(paper.compiler == .pdflatex)
        #expect(paper.source.orderedFiles.map(\.path) == ["main.tex", "sections/intro.tex", "references.bib"])
        let intro = try #require(paper.source.file("sections/intro.tex"))
        #expect(intro.name == "intro.tex" && intro.folder == "sections" && intro.isTeX)
    }

    @Test func editsTheSource() {
        var source = PaperSource(title: "T", files: [PaperFile(path: "main.tex", content: "a"), PaperFile(path: "b.tex", content: "b")], mainFile: "main.tex")
        source.write("main.tex", content: "A")
        source.write("refs.bib", content: "@misc{}")
        source.rename("main.tex", to: "paper.tex")
        source.delete("paper.tex")
        source.delete("b.tex")
        #expect(source.mainFile == "paper.tex")
        #expect(source.files.map(\.path) == ["paper.tex", "refs.bib"])
        #expect(source.file("paper.tex")?.content == "A")
    }

    @Test func validatesPathsLikeTheServer() {
        #expect(PaperPath.problem(with: "chapters/01-intro.tex") == nil)
        #expect(PaperPath.problem(with: "refs.bib") == nil)
        #expect(PaperPath.problem(with: "images/figure.png") == nil)
        #expect(PaperPath.problem(with: "figures/plot.tikz") == nil)
        for bad in ["../main.tex", "/abs.tex", "figure.svg", "a/./b.tex", "noext", "a b.tex", "", "a/b/c/d/e/f.tex"] {
            #expect(PaperPath.problem(with: bad) != nil, "\(bad)")
        }
    }

    @Test func readsCompileErrorsAndConflicts() throws {
        let body = APIErrorBody(code: "LATEX_COMPILE_FAILED", message: "LaTeX could not compile the paper", details: try SummaryJSON.decoder().decode(JSONValue.self, from: Data(#"""
            {"errors":[{"file":"sections/intro.tex","line":2,"message":"Undefined control sequence."},{"file":null,"line":null,"message":"Emergency stop."}],"log":"…"}
            """#.utf8)))
        let error = SummaryAPIError.server(status: 422, body: body)
        #expect(error.latexIssues?.map(\.location) == ["sections/intro.tex:2", nil])
        #expect(SummaryAPIError.server(status: 409, body: APIErrorBody(code: "PAPER_REVISION_CONFLICT", message: "")).isPaperRevisionConflict)
        #expect(SummaryAPIError.http(status: 500).latexIssues == nil)
    }

    @Test func decodesAPaperVersionAndRestore() throws {
        let detail = try SummaryJSON.decoder().decode(DocumentVersionDetail.self, from: Data(#"""
            {"version":4,"kind":"paper","actor":"agent","restoredFrom":null,"createdAt":"2026-10-09T08:00:00Z","title":"Gears","isCurrent":false,
             "content":{"title":"Gears","mainFile":"main.tex","compiler":"xelatex","files":[{"path":"main.tex","content":"x"}]}}
            """#.utf8))
        guard case .paper(let source) = detail.content else { Issue.record("expected paper content"); return }
        #expect(source.compiler == .xelatex && source.files.count == 1)

        let restored = try SummaryJSON.decoder().decode(DocumentVersionRestore.self, from: Data(#"{"version":null,"summary":null,"trip":null,"paper":\#(Self.paperJSON)}"#.utf8))
        #expect(restored.paper?.title == "Quantum Gears")
        #expect(SummaryKind(rawValue: "paper") == .paper && SummaryKind.known.contains(.paper))
    }
}
