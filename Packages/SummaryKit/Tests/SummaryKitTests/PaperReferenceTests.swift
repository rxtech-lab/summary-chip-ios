import Foundation
import Testing
@testable import SummaryKit

@Suite struct PaperReferenceTests {
    private static let paperJSON = #"""
        {"id":"p1","slug":"a1B2c3D4e5","revision":3,"visibility":"private","isOwner":true,
         "createdAt":"2026-10-09T08:00:00.000Z","updatedAt":"2026-10-09T09:00:00Z","shareUrl":"https://summary.rxlab.app/s/a1B2c3D4e5",
         "title":"Quantum Gears","mainFile":"main.tex","compiler":"pdflatex","version":2,"hasUnversionedChanges":false,"likedAt":null,
         "files":[{"path":"main.tex","content":"\\documentclass{article}"}],
         "references":[
           {"key":"knuth1984","file":"references.bib","line":1,"title":"The TeXbook","url":null,"status":"verified","issue":null,"message":"Found it.","checkedAt":"2026-10-09T09:00:00.000Z"},
           {"key":"ghost","file":"references.bib","line":8,"title":"A Fabricated Survey of Gears","url":"not a url {}","status":"error","issue":"reference_not_found","message":"No such work.","checkedAt":"2026-10-09T09:00:00.000Z"},
           {"key":"new","file":"references.bib","line":14,"title":null,"url":null,"status":"checking","issue":null,"message":null,"checkedAt":null},
           {"key":"odd","file":"references.bib","line":20,"title":null,"url":null,"status":"queued","issue":"future_issue","message":null,"checkedAt":null}
         ]}
        """#

    @Test func decodesReferencesAndTheirChecks() throws {
        let paper = try SummaryJSON.decoder().decode(Paper.self, from: Data(Self.paperJSON.utf8))
        #expect(paper.referenceList.map(\.status) == [.verified, .error, .checking, .unchecked])
        #expect(paper.referenceErrors.map(\.key) == ["ghost"])
        #expect(paper.referenceErrors.first?.issue == .referenceNotFound)
        #expect(paper.referenceList.last?.issue == .other)
        #expect(paper.isCheckingReferences)
        #expect(paper.referenceErrors.first?.location == "references.bib:8")
    }

    @Test func readsAPaperWithoutReferences() throws {
        let json = Self.paperJSON.replacing(#/,\s*"references":\[[\s\S]*\]\}/#, with: "}")
        let paper = try SummaryJSON.decoder().decode(Paper.self, from: Data(json.utf8))
        #expect(paper.references == nil && paper.referenceList.isEmpty && !paper.isCheckingReferences)
    }

    @Test func searchesThePDFByTheTitlesOpeningWords() {
        let reference = PaperReference(key: "k", file: "r.bib", line: 1, title: "Time, Clocks, and the Ordering of Events in a Distributed System", status: .error)
        #expect(reference.searchPhrases == ["Time, Clocks, and the Ordering of", "Time, Clocks, and the", "Time, Clocks, and"])
        #expect(PaperReference(key: "k", file: "r.bib", line: 1, title: "Gears", status: .error).searchPhrases.isEmpty)
        #expect(PaperReference(key: "k", file: "r.bib", line: 1, title: nil, status: .error).searchPhrases.isEmpty)
    }
}
