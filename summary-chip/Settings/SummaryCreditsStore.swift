import Foundation
import Observation
import RxSubscriptionIOS
import SummaryKit

/// Display cache only. Generation is always authorized by the Chippy server.
@MainActor
@Observable
final class SummaryCreditsStore {
    private(set) var client: Client?
    private(set) var entitlements: Entitlements?
    private(set) var connection: BillingConnection?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var sessionID = UUID()

    /// iOS tops up through the App Store; the Developer ID macOS build uses Stripe Checkout.
    #if os(iOS)
    static let usesInAppPurchase = true
    #else
    static let usesInAppPurchase = false
    #endif
    @ObservationIgnored private var transactionObserver: Task<Void, Never>?

    var points: Int? {
        guard let entitlements, let connection else { return nil }
        return entitlements.balances.first { $0.unit == connection.balanceUnit }?.available ?? 0
    }

    var allowance: UsageStatus? {
        guard let connection else { return nil }
        return entitlements?.usage.first { $0.key == connection.usageItem }
    }

    #if DEBUG
    func configurePreview(client: Client, connection: BillingConnection) {
        reset()
        self.client = client
        self.connection = connection
    }
    #endif

    func refresh(api: SummaryAPIClient, broker: SharedTokenBroker) async {
        guard !isLoading else { return }
        let sessionID = self.sessionID
        isLoading = true
        errorMessage = nil
        defer { if self.sessionID == sessionID { isLoading = false } }
        do {
            if client == nil {
                let configuration = try await api.billingConnection()
                guard configuration.publishableKey.hasPrefix("rxs_pk_"),
                      let userID = try await broker.currentBundle()?.subject, !userID.isEmpty else {
                    throw SummaryAPIError.notSignedIn
                }
                guard self.sessionID == sessionID, !Task.isCancelled else { return }
                connection = configuration
                let client = Client(
                    serverURL: configuration.serverURL,
                    publishableKey: configuration.publishableKey,
                    rxlabUserID: userID,
                    userToken: { forceRefresh in try await broker.accessToken(forceRefresh: forceRefresh) },
                    useIap: Self.usesInAppPurchase
                )
                self.client = client
                if client.useIap {
                    transactionObserver = client.observeTransactionUpdates { [weak self] _ in
                        Task { await self?.refresh(api: api, broker: broker) }
                    }
                }
            }
            guard let client else { return }
            let entitlements = try await client.entitlements()
            guard self.sessionID == sessionID, !Task.isCancelled else { return }
            self.entitlements = entitlements
        } catch {
            guard self.sessionID == sessionID, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        sessionID = UUID()
        transactionObserver?.cancel()
        transactionObserver = nil
        client = nil
        entitlements = nil
        connection = nil
        isLoading = false
        errorMessage = nil
    }
}
