import Foundation
import SummaryKit
import Testing
@testable import summary_chip

@MainActor
@Suite struct FlowcySubscriptionStoreTests {
    @Test func signingOutClearsVerifiedAccess() async {
        let store = makeStore(host: "plus.example")
        await store.refresh()
        #expect(store.state == .active(.flowcy))
        store.reset()
        #expect(store.state == .checking)
        #expect(!store.isActive)
    }

    @Test func subscriptionServiceFailureDoesNotUnlockAnotherAccount() async {
        let store = makeStore(host: "unavailable.example")
        await store.refresh()
        #expect(store.state == .unavailable)
        #expect(!store.isActive)
    }

    private func makeStore(host: String) -> FlowcySubscriptionStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionFixtureProtocol.self]
        return FlowcySubscriptionStore(api: SummaryAPIClient(
            baseURL: URL(string: "https://\(host)")!,
            tokenProvider: SubscriptionFixtureToken(),
            session: URLSession(configuration: configuration)
        ))
    }
}

private nonisolated struct SubscriptionFixtureToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "fixture-token" }
}

private nonisolated final class SubscriptionFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.path == "/api/v1/subscription" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let active = url.host == "plus.example"
        let body = active ? #"{"active":true,"provider":"flowcy","productId":null}"# : "{}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: active ? 200 : 503, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
