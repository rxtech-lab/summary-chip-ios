import RxSubscriptionIOS
import SummaryKit
import SwiftUI

/// App-owned top-up screen: current balance first, then each pack as a row whose button shows its price.
struct PointsTopUpView: View {
    let client: Client
    let points: Int?
    let onPurchased: () async -> Void

    @Environment(\.openURL) private var openURL
    @State private var topUps: [TopUpProduct] = []
    @State private var storePrices: [String: String] = [:]
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var purchasingID: String?
    @State private var status: String?
    @State private var purchaseFeedback: PurchaseFeedback?

    /// Purchase outcome for the haptic; a fresh id lets a repeated outcome fire again.
    private struct PurchaseFeedback: Equatable {
        let id = UUID()
        let feedback: SensoryFeedback
    }

    var body: some View {
        content
            .task { await load() }
            .overlay {
                if purchasingID != nil {
                    ActionStatusOverlay(client.useIap ? "Completing purchase…" : "Opening checkout…", isWorking: true)
                }
            }
            .statusAlert("Top Up Points", message: status) { status = nil }
            .sensoryFeedback(trigger: purchaseFeedback) { _, new in new?.feedback }
    }

    @ViewBuilder
    private var content: some View {
        if topUps.isEmpty, let loadError {
            ContentUnavailableView {
                Label("Top-ups unavailable", systemImage: "wifi.exclamationmark")
            } description: { Text(loadError) } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if topUps.isEmpty, isLoading {
            ProgressView("Loading top-ups…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            packs
        }
    }

    private var packs: some View {
        let available = topUps.filter { $0.eligible != false }
        let unavailable = topUps.filter { $0.eligible == false }
        return Form {
            Section {
                balance
                NavigationLink(value: CreditsRoute.usage) {
                    Label("Usage & Activity", systemImage: "chart.bar.doc.horizontal")
                }
                .accessibilityIdentifier("topup-usage")
            }
            Section {
                if available.isEmpty {
                    Text("No point packs are available right now.")
                        .foregroundStyle(.secondary)
                }
                ForEach(available) { row($0) }
            } header: {
                Text("Point packs")
            } footer: {
                Text(client.useIap
                     ? "One-time purchase through the App Store. Points are added to your account right away, with no recurring subscription."
                     : "Checkout opens securely in your browser. Points are added to your account once payment completes.")
            }
            if !unavailable.isEmpty {
                Section("Not available") {
                    ForEach(unavailable) { row($0) }
                }
            }
        }
        .formStyle(.grouped)
        .refreshable { await load() }
    }

    private var balance: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Current balance")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(points.map { "\($0.formatted()) points" } ?? "–")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.default, value: points)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("topup-balance")
    }

    private func row(_ topUp: TopUpProduct) -> some View {
        let isEligible = topUp.eligible != false
        return HStack(spacing: 14) {
            Image(systemName: isEligible ? "plus.circle.fill" : "lock.fill")
                .font(.title2)
                .foregroundStyle(isEligible ? Color.accentColor : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(topUp.amount.formatted()) \(topUp.unit ?? "points")")
                    .font(.headline.monospacedDigit())
                Text(isEligible ? subtitle(for: topUp) : eligibilityText(for: topUp))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button {
                Task { await purchase(topUp) }
            } label: {
                Text(price(for: topUp))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 64)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!isEligible || purchasingID != nil)
            .accessibilityLabel("Buy \(topUp.amount.formatted()) \(topUp.unit ?? "points") for \(price(for: topUp))")
            .accessibilityIdentifier("topup-buy-\(topUp.key)")
        }
        .padding(.vertical, 4)
    }

    private func subtitle(for topUp: TopUpProduct) -> String {
        if let description = topUp.description, !description.isEmpty { return description }
        return topUp.name
    }

    private func eligibilityText(for topUp: TopUpProduct) -> String {
        let rules = topUp.blockedBy?.map(\.ruleType) ?? []
        if rules.contains("purchase_limit") { return "Purchase limit reached" }
        if rules.contains("requires_role") { return "Membership required" }
        if rules.contains("requires_active_plan") || rules.contains("requires_any_plan") { return "Active plan required" }
        return "Not currently eligible"
    }

    private func price(for topUp: TopUpProduct) -> String {
        if let id = storeProductID(for: topUp), let price = storePrices[id] { return price }
        return SubscriptionFormatting.price(cents: topUp.priceAmountCents, currency: topUp.currency)
    }

    /// The StoreKit product to buy through, or `nil` to use Stripe Checkout.
    private func storeProductID(for topUp: TopUpProduct) -> String? {
        guard client.useIap else { return nil }
        return topUp.purchaseOptions.first { $0.provider == .appleAppStore && $0.flow == .storeKit }?.productID
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let catalog = try await client.catalog()
            topUps = catalog.topups
            loadError = nil
            let ids = catalog.topups.compactMap(storeProductID)
            if !ids.isEmpty {
                let products = try await client.storeProducts(productIDs: ids)
                storePrices = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0.displayPrice) })
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func purchase(_ topUp: TopUpProduct) async {
        purchasingID = topUp.id
        defer { purchasingID = nil }
        do {
            if let productID = storeProductID(for: topUp) {
                switch try await client.purchaseApple(productID: productID) {
                case .completed:
                    await onPurchased()
                    status = "\(topUp.amount.formatted()) \(topUp.unit ?? "points") added to your balance."
                    purchaseFeedback = PurchaseFeedback(feedback: .success)
                case .pending:
                    status = "Your purchase is waiting for approval. Points will be added once it's approved."
                    purchaseFeedback = PurchaseFeedback(feedback: .warning)
                case .cancelled:
                    break
                }
            } else {
                openURL(try await client.checkoutTopUp(id: topUp.id).checkoutURL)
            }
        } catch {
            status = error.localizedDescription
            purchaseFeedback = PurchaseFeedback(feedback: .error)
        }
    }
}
