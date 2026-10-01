import RxSubscriptionIOS
import SummaryKit
import SwiftUI

/// Account usage and the purchase flow occupy separate screens inside this sheet.
struct SummaryCreditsSheet: View {
    let environment: AppEnvironment
    var opensTopUps = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [CreditsRoute] = []
    @State private var isRestoring = false
    @State private var status: String?
    @State private var lastReportedConnectionError: String?

    private var store: SummaryCreditsStore { environment.credits }

    var body: some View {
        NavigationStack(path: $path) {
            account
                .navigationTitle("Summaries & Points")
                .navigationDestination(for: CreditsRoute.self) { _ in topUps }
                .toolbar { doneButton }
        }
        .summarySheetSize()
        .interactiveDismissDisabled(isRestoring)
        .task {
            if opensTopUps { path = [.topUps] }
            // Refresh fulfillment in place while Apple's purchase sheet or Stripe Checkout is open or returning.
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .overlay {
            if isRestoring {
                ActionStatusOverlay("Restoring purchases…", isWorking: true)
            }
        }
        .statusAlert("Summary Points", message: status) { status = nil }
    }

    private var account: some View {
        Form {
            Section("Points") {
                LabeledContent("Available", value: store.points.map { $0.formatted() } ?? "–")
                    .accessibilityIdentifier("summary-points")
                NavigationLink(value: CreditsRoute.topUps) {
                    Label("Top Up Points", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("summary-topup")
            }
            Section("Free summaries") {
                if let allowance = store.allowance {
                    LabeledContent("Remaining", value: allowance.remaining.map { $0.formatted() } ?? "Unlimited")
                        .accessibilityIdentifier("summary-free-remaining")
                    if let limit = allowance.limit {
                        LabeledContent("Allowance", value: limit.formatted())
                    }
                    if let reset = allowance.resetsAt {
                        LabeledContent("Resets", value: reset.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    Text(store.isLoading ? "Loading allowance…" : "Allowance unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if SummaryCreditsStore.usesInAppPurchase {
                    Button { Task { await restore() } } label: {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.client == nil || isRestoring)
                    .accessibilityIdentifier("summary-restore")
                }
                Button { Task { await refresh(reportRepeatedError: true) } } label: {
                    Label("Refresh Usage", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .disabled(store.isLoading)
            } footer: {
                Text(SummaryCreditsStore.usesInAppPurchase
                     ? "Your free allowance and point charges are set by the server. Top-ups add points without a recurring subscription."
                     : "Your free allowance and point charges are set by the server. Top-ups open Stripe Checkout in your browser and add points without a recurring subscription.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var topUps: some View {
        Group {
            if let client = store.client {
                PointsTopUpView(client: client, points: store.points) { await refresh() }
            } else if let error = store.errorMessage {
                ContentUnavailableView {
                    Label("Top-ups unavailable", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await refresh(reportRepeatedError: true) } }
                }
            } else {
                ProgressView("Loading top-ups…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Top Up Points")
        .toolbar { doneButton }
    }

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }.disabled(isRestoring)
        }
    }

    private func refresh(reportRepeatedError: Bool = false) async {
        await store.refresh(api: environment.api, broker: environment.tokenBroker)
        if let error = store.errorMessage,
           reportRepeatedError || error != lastReportedConnectionError {
            status = error
        }
        // Polling must not repeatedly present an alert for the same outage.
        lastReportedConnectionError = store.errorMessage
    }

    private func restore() async {
        guard let client = store.client else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            _ = try await client.restoreApplePurchases()
            await refresh()
            status = "Purchases restored. Consumable top-ups are saved in your account balance."
        } catch { status = error.localizedDescription }
    }

    private enum CreditsRoute: Hashable { case topUps }
}
