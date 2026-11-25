import Foundation
import Testing
@testable import SummaryKit

@Suite(.serialized) struct BillingRequestTests {
    @Test func flowcyUsagePercentagesRespectTheAccountLimit() throws {
        let fixture = """
        {"unit":"micro_usd","meters":[
          {"key":"agent_cost_5h","used":1250000,"limit":5000000},
          {"key":"agent_cost_7d","used":0,"limit":1000000},
          {"key":"agent_cost_30d","used":1500000,"limit":1000000},
          {"key":"agent_cost_5h","used":0,"limit":0},
          {"key":"agent_cost_7d","used":1250000,"limit":null}
        ]}
        """
        let usage = try SummaryJSON.decoder().decode(FlowcyModelUsage.self, from: Data(fixture.utf8))
        #expect(usage.meters.map(\.fractionUsed) == [0.25, 0, 1.5, nil, nil])
    }

    @Test func xcodeUsesTheSameEnvironmentForAccessAndGeneration() async throws {
        BillingRequestProtocol.requests.clear()
        let api = client(proof: .xcode)
        let membership = try await api.flowcySubscription()
        #expect(membership.productId == FlowcySubscription.appleProductID)
        do {
            _ = try await api.createSummary(.init(source: .text("A summary to meter.", title: nil), options: .init()))
            Issue.record("Expected the fixture's membership refusal")
        } catch let error as SummaryAPIError {
            #expect(error.needsSubscription)
        }
        let requests = BillingRequestProtocol.requests.values
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "x-storekit-environment") == "xcode")
            #expect(request.value(forHTTPHeaderField: "x-storekit-app-transaction") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        }
    }

    @Test func appleProofAppliesToAccessAndLibraryReads() async throws {
        BillingRequestProtocol.requests.clear()
        let api = client(proof: .appleSigned("signed-app-transaction"))
        _ = try await api.flowcySubscription()
        _ = try await api.listSummaries()
        let requests = BillingRequestProtocol.requests.values
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "x-storekit-app-transaction") == "signed-app-transaction")
        #expect(requests[0].value(forHTTPHeaderField: "x-storekit-environment") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "x-storekit-app-transaction") == "signed-app-transaction")
        #expect(requests[1].value(forHTTPHeaderField: "x-storekit-environment") == nil)
    }

    @Test func chatReportsThatTheSubscriptionIsRequired() async throws {
        BillingRequestProtocol.requests.clear()
        let chat = ChatStreamClient(api: client(proof: .appleSigned("signed-app-transaction")))
        do {
            for try await _ in chat.stream(messages: [ChatUIMessage(role: .user, text: "hello")]) {}
            Issue.record("Expected the fixture's membership refusal")
        } catch let error as SummaryAPIError {
            #expect(error.needsSubscription)
        }
        let requests = BillingRequestProtocol.requests.values
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "x-storekit-app-transaction") == "signed-app-transaction")
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
        if request.url?.lastPathComponent == "subscription" {
            status = 200
            json = """
            {"active":false,"provider":null,"productId":"com.rxlab.chippy.flowcy.plus.monthly"}
            """
        } else if request.url?.path == "/api/v1/chat" {
            status = 402
            json = """
            {"error":{"code":"FLOWCY_SUBSCRIPTION_REQUIRED","message":"Flowcy Plus is required."}}
            """
        } else if request.httpMethod == "POST" {
            status = 402
            json = """
            {"error":{"code":"FLOWCY_SUBSCRIPTION_REQUIRED","message":"Flowcy Plus is required."}}
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
