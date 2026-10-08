import Foundation
import Testing
@testable import SummaryKit

@Suite(.serialized) struct PaperExportTests {
    @Test func sendsExplicitFormatLanguageAndVersion() async throws {
        PaperExportProtocol.requests.clear()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaperExportProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://papers.test")!, tokenProvider: PaperExportToken(), session: URLSession(configuration: configuration))
        let result = try await api.exportPaper(id: "p1", format: .docx, language: .zhHant, version: 3)
        let request = try #require(PaperExportProtocol.requests.values.last)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/v1/papers/p1/export")
        #expect(components.queryItems?.contains(URLQueryItem(name: "format", value: "docx")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "lang", value: "zh-Hant")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "version", value: "3")) == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(result.format == .docx && result.language == "zh-Hant" && result.revision == 7)
        _ = try await api.exportPaper(id: "p1", format: .pdf, language: .auto)
        #expect(PaperExportProtocol.requests.values.last?.url?.query?.contains("lang=original") == true)
    }

    @Test func readsTranslatedPaperAndKeepsOldResponsesCompatible() throws {
        let json = #"""
            {"id":"p1","slug":"test","revision":7,"visibility":"private","isOwner":true,
             "createdAt":"2026-10-09T08:00:00Z","updatedAt":"2026-10-09T08:00:00Z","shareUrl":"https://papers.test/s/test",
             "title":"研究","files":[{"path":"main.tex","content":"translated"}],"mainFile":"main.tex","compiler":"xelatex",
             "version":1,"hasUnversionedChanges":false,"originalLanguage":"en","language":"zh-Hant","displayLanguage":"zh-Hant","translationOutdated":true}
            """#
        let paper = try SummaryJSON.decoder().decode(Paper.self, from: Data(json.utf8))
        #expect(paper.isTranslated && paper.translationOutdated == true)
        #expect(paper.writtenLanguage == "en" && paper.readingLanguage == "zh-Hant")
        #expect(paper.rendering.enabled == false)
    }

    @Test func renderingOptionsRoundTripWithoutChangingSource() throws {
        var style = PaperRendering()
        style.enabled = true
        style.columns = 2
        style.pageSize = "letter"
        style.fontFamily = "serif"
        style.headerText = "Draft"
        let data = try SummaryJSON.encoder().encode(style)
        #expect(try SummaryJSON.decoder().decode(PaperRendering.self, from: data) == style)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["columns"] as? Int == 2)
        #expect(body["marginLeft"] as? Double == 20)
        #expect(body["pageNumbers"] as? String == "footer-center")
    }
}

private struct PaperExportToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}

private final class PaperExportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
    func clear() { lock.withLock { storage.removeAll() } }
}

private final class PaperExportProtocol: URLProtocol, @unchecked Sendable {
    static let requests = PaperExportRecorder()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "papers.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "Content-Language": "zh-Hant", "X-Paper-Revision": "7"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("word bytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
