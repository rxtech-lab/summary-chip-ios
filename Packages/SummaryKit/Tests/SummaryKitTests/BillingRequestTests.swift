import Foundation
import Testing
@testable import SummaryKit

@Suite(.serialized) struct BillingRequestTests {
    @Test func xcodeUsesTheSameEnvironmentForStorefrontAndGeneration() async throws {
        BillingRequestProtocol.requests.clear()
        let api = client(proof: .xcode)
        let connection = try await api.billingConnection()
        #expect(connection.publishableKey == "rxs_pk_xcode_test")
        do {
            _ = try await api.createSummary(.init(source: .text("A summary to meter.", title: nil), options: .init()))
            Issue.record("Expected the fixture's usage refusal")
        } catch let error as SummaryAPIError {
            #expect(error.needsTopUp)
        }
        let requests = BillingRequestProtocol.requests.values
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "x-storekit-environment") == "xcode")
            #expect(request.value(forHTTPHeaderField: "x-storekit-app-transaction") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        }
    }

    @Test func appleProofAndOrdinaryReadsKeepTheirExistingRouting() async throws {
        BillingRequestProtocol.requests.clear()
        let api = client(proof: .appleSigned("signed-app-transaction"))
        _ = try await api.billingConnection()
        _ = try await api.listSummaries()
        let requests = BillingRequestProtocol.requests.values
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "x-storekit-app-transaction") == "signed-app-transaction")
        #expect(requests[0].value(forHTTPHeaderField: "x-storekit-environment") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "x-storekit-app-transaction") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "x-storekit-environment") == nil)
    }

    private func client(proof: StoreKitBillingProof) -> SummaryAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingRequestProtocol.self]
        return SummaryAPIClient(baseURL: URL(string: "https://billing.test")!, tokenProvider: BillingTestToken(),
            session: URLSession(configuration: configuration), billingProofProvider: { proof })
    }
}

private struct BillingTestToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}

private final class BillingRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
    func clear() { lock.withLock { storage.removeAll() } }
}

private final class BillingRequestProtocol: URLProtocol, @unchecked Sendable {
    static let requests = BillingRequestRecorder()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "billing.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        let status: Int
        let json: String
        if request.url?.lastPathComponent == "billing" {
            status = 200
            json = """
            {"serverURL":"https://subscription.test","publishableKey":"rxs_pk_xcode_test","usageItem":"daily_summary_generation","balanceUnit":"points"}
            """
        } else if request.httpMethod == "POST" {
            status = 402
            json = """
            {"error":{"code":"SUMMARY_ALLOWANCE_EXHAUSTED","message":"Top up to continue."}}
            """
        } else {
            status = 200
            json = """
            {"items":[],"nextCursor":null}
            """
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
