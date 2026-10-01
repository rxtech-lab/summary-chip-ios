import Foundation
import Testing
@testable import SummaryKit

@Suite(.serialized) struct DeviceReaderTests {
    private let page = URL(string: "https://xhslink.cn/o/1RVs1hjAwxb")!

    @Test func readsAPageTheServerCannotOnTheDevice() async throws {
        DeviceReaderProtocol.bodies.clear()
        let api = client { url in
            WebpageSource(url: url, title: "笔记", content: "Read in the web view on the device.", siteName: "小红书", lang: "zh")
        }
        let summary = try await api.createSummary(from: .url(page), options: .init())
        #expect(summary.id.isEmpty == false)
        let bodies = DeviceReaderProtocol.bodies.values
        #expect(bodies.count == 2)
        #expect(bodies[0]["deviceReader"] as? Bool == true)
        #expect((bodies[0]["source"] as? [String: Any])?["type"] as? String == "url")
        let resent = try #require(bodies[1]["source"] as? [String: Any])
        #expect(resent["type"] as? String == "webpage")
        #expect(resent["url"] as? String == page.absoluteString)
        #expect(resent["content"] as? String == "Read in the web view on the device.")
    }

    @Test func reportsAnUnreadablePageWhenTheDeviceCannotReadItEither() async throws {
        DeviceReaderProtocol.bodies.clear()
        let api = client { _ in throw WebPageReader.ReadError.timedOut }
        for input in [SummaryInput.url(page), .text("国庆档… \(page.absoluteString) 先复制文字", title: nil)] {
            do {
                _ = try await api.createSummary(from: input, options: .init())
                Issue.record("Expected UnreadablePageError")
            } catch let error as UnreadablePageError {
                #expect(error.url == page)
            }
        }
        #expect(DeviceReaderProtocol.bodies.values.count == 2)
    }

    @Test func summarisesSharedTextAsIsWhenAsked() async throws {
        DeviceReaderProtocol.bodies.clear()
        let api = client { _ in throw WebPageReader.ReadError.noContent }
        _ = try await api.createSummary(from: .text("国庆档… \(page.absoluteString) 先复制文字", title: nil), options: .init(), followLinks: false)
        let bodies = DeviceReaderProtocol.bodies.values
        #expect(bodies.count == 1)
        #expect(bodies[0]["followLinks"] as? Bool == false)
    }

    @Test func decodesTheDeviceReadURL() {
        let error = SummaryAPIError.server(status: 422, body: APIErrorBody(
            code: "SOURCE_NEEDS_DEVICE", message: "", details: .object(["url": .string(page.absoluteString)])))
        #expect(error.deviceReadURL == page)
        #expect(SummaryAPIError.server(status: 422, body: APIErrorBody(code: "NO_CONTENT", message: "")).deviceReadURL == nil)
    }

    private func client(reader: @escaping SummaryAPIClient.PageReader) -> SummaryAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceReaderProtocol.self]
        return SummaryAPIClient(baseURL: URL(string: "https://device-reader.test")!, tokenProvider: DeviceReaderToken(),
            session: URLSession(configuration: configuration), billingProofProvider: { nil }, pageReader: reader)
    }
}

private struct DeviceReaderToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}

private final class BodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: Any]] = []
    var values: [[String: Any]] { lock.withLock { storage } }
    func append(_ body: [String: Any]) { lock.withLock { storage.append(body) } }
    func clear() { lock.withLock { storage.removeAll() } }
}

/// The server can't read `url` sources or links in text (`SOURCE_NEEDS_DEVICE`); it summarises anything else.
private final class DeviceReaderProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = BodyRecorder()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "device-reader.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let body = (try? JSONSerialization.jsonObject(with: Self.data(of: request))) as? [String: Any] ?? [:]
        Self.bodies.append(body)
        let source = body["source"] as? [String: Any] ?? [:]
        let type = source["type"] as? String
        let needsDevice = type == "url" || (type == "text" && body["followLinks"] as? Bool != false)
        let status = needsDevice ? 422 : 201
        let data: Data
        if needsDevice {
            data = Data("""
            {"error":{"code":"SOURCE_NEEDS_DEVICE","message":"Read it on the device","details":{"url":"https://xhslink.cn/o/1RVs1hjAwxb","cause":"SOURCE_HTTP_ERROR"}}}
            """.utf8)
        } else {
            let fixture = Bundle.module.url(forResource: "summary.json", withExtension: nil, subdirectory: "Fixtures")!
            data = (try? Data(contentsOf: fixture)) ?? Data()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession moves the body into a stream before protocols see it.
    private static func data(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
