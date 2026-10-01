import Foundation
import RxSubscriptionIOS
import SummaryKit
import Testing
@testable import summary_chip

@MainActor
@Suite struct SummaryCreditsTests {
    @Test func absentBalanceIsZeroAndSignOutDropsUsage() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [CreditsPreviewProtocol.self]
        let connection = try SummaryJSON.decoder().decode(BillingConnection.self, from: Data("""
        {"serverURL":"https://credits-preview.invalid/zero/","publishableKey":"rxs_pk_sandbox_preview","usageItem":"remote_allowance","balanceUnit":"points"}
        """.utf8))
        let store = SummaryCreditsStore()
        store.configurePreview(client: Client(
            serverURL: connection.serverURL, publishableKey: connection.publishableKey,
            rxlabUserID: "preview-user", userToken: { _ in "preview-token" },
            session: URLSession(configuration: session)
        ), connection: connection)
        let broker = SharedTokenBroker(vault: InMemoryTokenVault(), tokenURL: URL(string: "https://auth.invalid/token")!, clientID: "preview", lockURL: nil)
        let api = SummaryAPIClient(baseURL: connection.serverURL, tokenProvider: broker)
        #expect(store.points == nil)
        await store.refresh(api: api, broker: broker)
        #expect(store.errorMessage == nil)
        #expect(store.points == 0)
        #expect(store.allowance?.limit == 7)
        #expect(store.allowance?.remaining == 2)
        store.reset()
        #expect(store.points == nil)
        #expect(store.allowance == nil)
        #expect(store.client == nil)
        #expect(store.connection == nil)
    }
}
