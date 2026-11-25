import StoreKit
import SummaryKit
import SwiftUI

struct FlowcySubscriptionView: View {
    let environment: AppEnvironment
    var isSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var showsDeletion = false
    @State private var confirmsSignOut = false
    @State private var showsAppleSubscriptions = false
    @State private var deletion: AccountDeletionState = .none

    private var store: FlowcySubscriptionStore { environment.subscription }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.indigo)
                        .accessibilityHidden(true)
                    Text("Flowcy Plus")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    description
                        .foregroundStyle(.secondary)
                    actions
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(isSheet ? "Subscription" : "Chippy")
            .summaryInlineNavigationTitle()
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                } else {
                    ToolbarItem(placement: .summaryTrailing) {
                        Menu("Account", systemImage: "person.crop.circle") {
                            Button("Sign Out", role: .destructive) { confirmsSignOut = true }
                            Button("Delete Account…", role: .destructive) { showsDeletion = true }
                        }
                        .disabled(store.activity != nil)
                    }
                }
            }
            .navigationDestination(for: LegalDocument.self) { document in
                LegalDocumentView(document: document, baseURL: environment.configuration.apiBaseURL)
            }
        }
        .summarySheetFrame(minWidth: 520, minHeight: 480)
        .disabled(store.activity != nil)
        .overlay {
            if let activity = store.activity { ActionStatusOverlay(activity, isWorking: true) }
        }
        .statusAlert("Subscription", message: store.error) { store.error = nil }
        .statusAlert("App Store", message: store.notice) { store.notice = nil }
        .sensoryFeedback(.success, trigger: store.isActive) { _, active in active }
        .sensoryFeedback(.error, trigger: store.error) { _, error in error != nil }
        .confirmationDialog("Sign out of Chippy?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await environment.signOut() } }
        }
        .sheet(isPresented: $showsDeletion) {
            DeleteAccountSheet(environment: environment, state: $deletion)
                .task { deletion = (try? await environment.api.accountDeletionState()) ?? .none }
        }
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showsAppleSubscriptions)
        #endif
        .accessibilityIdentifier("flowcy-subscription")
    }

    @ViewBuilder
    private var description: some View {
        switch store.state {
        case .checking:
            ProgressView("Checking access…")
        case .required:
            Text("Subscribe to Flowcy Plus to unlock AI features in Chippy — including AI summaries, chat, voice, podcasts, audiobooks, and translations. You can still use the app and add chips without a subscription.")
        case .active:
            Text("Your Flowcy Plus subscription unlocks all AI features in Chippy.")
        case .unavailable:
            Text("Chippy could not check your Flowcy Plus subscription. Try again in a moment.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        #if os(iOS)
        if let price = store.displayPrice, !store.isActive {
            Button {
                Task { await store.purchase() }
            } label: {
                Text("Subscribe for \(price) per month")
            }
            .buttonStyle(.borderedProminent)
            Text("Renews monthly until canceled. Manage or cancel in your Apple Account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                NavigationLink("Privacy Policy", value: LegalDocument.privacy)
            }
            .font(.footnote)
        } else if store.state == .required {
            Text("The App Store subscription is currently unavailable.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if store.state == .active(.apple) {
            Button("Manage App Store Subscription") { showsAppleSubscriptions = true }
        }
        if !store.isActive {
            Button("Restore Purchases") { Task { await store.restore() } }
        }
        #elseif os(macOS)
        if store.state == .active(.apple) {
            Link("Manage App Store Subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
        } else {
            Link(store.isActive ? "Manage Flowcy Subscription" : "Subscribe to Flowcy Plus",
                 destination: URL(string: "https://www.flowcy.dev/dashboard/settings/billing")!)
                .buttonStyle(.borderedProminent)
        }
        #endif
        if store.state != .checking {
            Button("Check Access") { Task { await store.checkAccess() } }
        }
    }
}
