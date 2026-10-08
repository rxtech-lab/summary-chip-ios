import Foundation
import Testing
@testable import SummaryKit

@Suite(.serialized) struct PaperUploadTests {
    @Test func uploadsDirectlyToS3WithoutForwardingTheBearerToken() async throws {
        PaperUploadProtocol.requests.clear()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaperUploadProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://papers.test")!, tokenProvider: PaperUploadToken(), session: URLSession(configuration: configuration))
        let data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let file = try await api.uploadPaperImage(path: "images/example.png", data: data)
        #expect(file.asset == PaperAsset(key: "uploads/staged.png", mimeType: "image/png", byteSize: data.count))
        #expect(file.content.isEmpty)
        let requests = PaperUploadProtocol.requests.values
        #expect(requests.count == 2)
        let ticket = try #require(requests.first)
        let upload = try #require(requests.last)
        #expect(ticket.url?.path == "/api/v1/uploads")
        #expect(ticket.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(upload.url?.host == "storage.test")
        #expect(upload.httpMethod == "PUT")
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(upload.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(upload.value(forHTTPHeaderField: "x-storekit-app-transaction") == nil)
    }
}

private struct PaperUploadToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}

private final class PaperUploadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
    func clear() { lock.withLock { storage.removeAll() } }
}

private final class PaperUploadProtocol: URLProtocol, @unchecked Sendable {
    static let requests = PaperUploadRecorder()
    override class func canInit(with request: URLRequest) -> Bool { ["papers.test", "storage.test"].contains(request.url?.host) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        let json = request.url?.host == "papers.test"
            ? #"{"key":"uploads/staged.png","uploadUrl":"https://storage.test/image?signature=fixture","method":"PUT","headers":{"content-type":"image/png"}}"# : ""
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
