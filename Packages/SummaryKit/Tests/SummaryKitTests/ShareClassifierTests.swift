import Foundation
import Testing
@testable import SummaryKit

@Suite struct ShareClassifierTests {
    let page = URL(string: "https://example.com/post")!
    let longText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 20)

    @Test func preprocessingBecomesWebpage() {
        let raw = RawShareContents(preprocessing: ["url": page.absoluteString, "title": "Post", "siteName": "Example", "lang": "en", "content": longText], url: page)
        guard case .webpage(let source) = ShareClassifier.classify(raw) else { Issue.record("expected webpage"); return }
        #expect(source.title == "Post")
        #expect(source.siteName == "Example")
        #expect(source.url == page)
    }

    @Test func thinPreprocessingFallsBackToURL() {
        let raw = RawShareContents(preprocessing: ["url": page.absoluteString, "content": "tiny"])
        #expect(ShareClassifier.classify(raw) == .url(page))
    }

    @Test func pdfKeepsSafariURL() {
        let file = URL(fileURLWithPath: "/tmp/paper")
        let raw = RawShareContents(preprocessing: ["url": "https://example.com/paper.pdf", "content": longText], pdfFile: file, pdfFilename: "paper", url: URL(string: "https://example.com/paper.pdf"))
        #expect(ShareClassifier.classify(raw) == .pdf(fileURL: file, filename: "paper.pdf", sourceURL: URL(string: "https://example.com/paper.pdf")))
    }

    @Test func plainURLAndText() {
        #expect(ShareClassifier.classify(RawShareContents(url: page)) == .url(page))
        #expect(ShareClassifier.classify(RawShareContents(text: "  https://example.com/post \n")) == .url(page))
        #expect(ShareClassifier.classify(RawShareContents(text: "Some thoughts about https://example.com/post")) == .text("Some thoughts about https://example.com/post", title: nil))
        #expect(ShareClassifier.classify(RawShareContents(url: URL(string: "file:///tmp/x")!)) == nil)
        #expect(ShareClassifier.classify(RawShareContents(text: "   ")) == nil)
    }
}
