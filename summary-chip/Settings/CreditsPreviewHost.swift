#if DEBUG
import Foundation
import RxSubscriptionIOS
import SummaryKit
import SwiftUI

/// Offline review fixture uses the real RxSubscription client and real credits sheet.
struct CreditsPreviewHost: View {
    @State private var environment = AppEnvironment.live()
    @State private var showsCredits = false

    var body: some View {
        Button("Summaries & Points") { showsCredits = true }
            .sheet(isPresented: $showsCredits) {
                SummaryCreditsSheet(environment: environment,
                                    opensTopUps: ProcessInfo.processInfo.arguments.contains("--preview-topups"))
            }
            .task {
                let session = URLSessionConfiguration.ephemeral
                session.protocolClasses = [CreditsPreviewProtocol.self]
                let connection = try! SummaryJSON.decoder().decode(BillingConnection.self, from: Data("""
                {"serverURL":"https://credits-preview.invalid","publishableKey":"rxs_pk_sandbox_preview","usageItem":"remote_allowance","balanceUnit":"points"}
                """.utf8))
                let serverURL = ProcessInfo.processInfo.arguments.contains("--preview-credits-error")
                    ? connection.serverURL.appendingPathComponent("error") : connection.serverURL
                environment.credits.configurePreview(client: Client(
                    serverURL: serverURL, publishableKey: connection.publishableKey,
                    rxlabUserID: "preview-user", userToken: { _ in "preview-token" },
                    useIap: SummaryCreditsStore.usesInAppPurchase,
                    session: URLSession(configuration: session)
                ), connection: connection)
                showsCredits = true
            }
    }
}

nonisolated final class CreditsPreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if request.url?.path.contains("/error/") == true {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let json: String
        switch request.url?.lastPathComponent {
        case "entitlements": json = """
        {"user":{"id":"preview-user","rxlabUserId":"preview-user","level":0},"plans":[],"roles":[],"permissions":[],"features":{},
        "balances":[{"unit":"points","name":"Points","amount":120,"available":120,"precision":0}],
        "usage":[{"key":"remote_allowance","name":"Free summaries","used":5,"limit":7,"remaining":2,"resetPolicy":"daily","resetsAt":"2026-10-02T00:00:00Z"}]}
        """
        case "catalog": json = """
        {"plans":[{"id":"hidden-plan","key":"hidden-plan","name":"Recurring plan","planGroup":"default","billingInterval":"month","intervalCount":1,"priceAmountCents":100,"currency":"usd","trialDays":0,"purchaseOptions":[]}],
        "topups":[{"id":"points-100","key":"points-100","name":"100 point pack","unit":"points","amount":100,"priceAmountCents":199,"currency":"usd","eligible":true,"purchaseOptions":[]}]}
        """
        default: json = "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = request.url?.path.contains("/zero/") == true
            ? json.replacingOccurrences(of: "[{\"unit\":\"points\",\"name\":\"Points\",\"amount\":120,\"available\":120,\"precision\":0}]", with: "[]")
            : json
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
