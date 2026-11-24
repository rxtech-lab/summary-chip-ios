import Foundation
import Observation
import StoreKit
import SummaryKit

@Observable
final class FlowcySubscriptionStore {
    enum State: Equatable {
        case checking
        case required
        case active(FlowcySubscription.Provider)
        case unavailable
    }

    private(set) var state: State = .checking
    private(set) var activity: String?
    var notice: String?
    var error: String?
    private let api: SummaryAPIClient
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var refreshID = UUID()
    #if os(iOS)
    private(set) var product: Product?
    @ObservationIgnored private var updates: Task<Void, Never>?

    var displayPrice: String? {
        #if DEBUG
        if let previewPrice { return previewPrice }
        #endif
        return product?.displayPrice
    }
    #endif

    init(api: SummaryAPIClient) { self.api = api }

    #if DEBUG
    @ObservationIgnored private var isPreview = false
    private var previewPrice: String?

    func enablePreviewAccess() {
        isPreview = true
        state = .active(.flowcy)
    }

    func enablePurchasePreview(price: String) {
        isPreview = true
        state = .required
        previewPrice = price
    }
    #endif

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    func connect() async {
        #if os(iOS)
        if updates == nil {
            let session = sessionID
            updates = Task { [weak self] in
                for await result in Transaction.updates {
                    guard let self, self.sessionID == session, !Task.isCancelled else { return }
                    guard case .verified(let transaction) = result,
                          transaction.productID == FlowcySubscription.appleProductID else { continue }
                    do {
                        try await self.submit(result, session: session)
                        await self.refresh()
                    } catch { continue }
                }
            }
        }
        #endif
        await refresh()
        #if os(iOS)
        if !isActive {
            let session = sessionID
            if (try? await recoverPurchases(session: session)) == true, session == sessionID { await refresh() }
        }
        #endif
    }

    func refresh() async {
        #if DEBUG
        if isPreview { return }
        #endif
        let revision = UUID()
        refreshID = revision
        do {
            let status = try await api.flowcySubscription()
            guard refreshID == revision, !Task.isCancelled else { return }
            state = status.active ? .active(status.provider ?? .flowcy) : .required
            #if os(iOS)
            if let id = status.productId {
                let products = try? await Product.products(for: [id])
                guard refreshID == revision, !Task.isCancelled else { return }
                product = products?.first(where: { $0.type == .autoRenewable })
            } else {
                product = nil
            }
            #endif
        } catch {
            guard refreshID == revision, !Task.isCancelled, !isActive else { return }
            state = .unavailable
        }
    }

    func reset() {
        sessionID = UUID()
        refreshID = UUID()
        state = .checking
        activity = nil
        error = nil
        notice = nil
        #if os(iOS)
        updates?.cancel()
        updates = nil
        product = nil
        #endif
    }

    func checkAccess() async {
        await perform(String(localized: "Checking Flowcy Plus…")) { _ in await self.refresh() }
    }

    private func perform(_ title: String, operation: (UUID) async throws -> Void) async {
        guard activity == nil else { return }
        let session = sessionID
        activity = title
        defer { if session == sessionID { activity = nil } }
        do {
            try await operation(session)
        } catch is CancellationError {
        } catch {
            if session == sessionID { self.error = error.localizedDescription }
        }
    }

    #if os(iOS)
    func purchase() async {
        guard let product, !isActive else { return }
        await perform(String(localized: "Connecting to the App Store…")) { session in
            let token = try await self.api.flowcyAppleAccountToken()
            try self.requireSession(session)
            switch try await product.purchase(options: [.appAccountToken(token)]) {
            case .success(let result):
                try await self.submit(result, session: session)
                await self.refresh()
            case .pending:
                try self.requireSession(session)
                self.notice = String(localized: "Your purchase is waiting for approval. Chippy will check it when Apple confirms it.")
            case .userCancelled:
                break
            @unknown default:
                throw PurchaseError.unverified
            }
        }
    }

    func restore() async {
        await perform(String(localized: "Restoring App Store purchases…")) { session in
            try await AppStore.sync()
            let found = try await self.recoverPurchases(session: session)
            try self.requireSession(session)
            await self.refresh()
            if !found, !self.isActive, session == self.sessionID {
                self.notice = String(localized: "No active Flowcy Plus purchase was found for this Apple Account.")
            }
        }
    }

    private func recoverPurchases(session: UUID) async throws -> Bool {
        var submitted: Set<UInt64> = []
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result,
                  transaction.productID == FlowcySubscription.appleProductID else { continue }
            try await submit(result, session: session)
            submitted.insert(transaction.id)
        }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == FlowcySubscription.appleProductID,
                  !submitted.contains(transaction.id) else { continue }
            try await submit(result, session: session)
            submitted.insert(transaction.id)
        }
        return !submitted.isEmpty
    }

    private func submit(_ result: VerificationResult<Transaction>, session: UUID) async throws {
        try requireSession(session)
        guard case .verified(let transaction) = result else { throw PurchaseError.unverified }
        try await api.submitFlowcyAppleTransaction(result.jwsRepresentation)
        await transaction.finish()
        try requireSession(session)
    }

    private func requireSession(_ session: UUID) throws {
        guard session == sessionID else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private enum PurchaseError: LocalizedError {
        case unverified

        var errorDescription: String? { String(localized: "The App Store purchase could not be verified. Try restoring your purchases.") }
    }
    #endif
}
