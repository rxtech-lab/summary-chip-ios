import SummaryKit
import SwiftUI

/// Requesting account deletion and, for the whole 7-day grace period, taking it back.
struct DeleteAccountSheet: View {
    let environment: AppEnvironment
    @Binding var state: AccountDeletionState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDeletion = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: state.pendingDeletion ? "clock.badge.exclamationmark" : "person.crop.circle.badge.xmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                        (state.pendingDeletion ? Text("Deletion Scheduled") : Text("Delete Your Account"))
                            .font(.title2.weight(.bold))
                        Text(summary)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("What gets deleted") {
                    Label("Every summary you created, including shared links", systemImage: "text.quote")
                    Label("Uploaded PDFs and generated images", systemImage: "photo.on.rectangle")
                    Label("Your library history of opened summaries", systemImage: "clock.arrow.circlepath")
                    Label("Your RxLab sign-in account", systemImage: "person.crop.circle")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("account-deletion-error")
                    }
                }

                Section {
                    if state.pendingDeletion {
                        Button {
                            perform { try await environment.api.cancelAccountDeletion() }
                        } label: {
                            actionLabel("Keep My Account")
                        }
                        .accessibilityIdentifier("cancel-account-deletion")
                    } else {
                        Button(role: .destructive) {
                            confirmsDeletion = true
                        } label: {
                            actionLabel("Delete My Account")
                        }
                        .accessibilityIdentifier("confirm-delete-account")
                    }
                }
                .disabled(isWorking)
            }
            .formStyle(.grouped)
            .navigationTitle("Delete Account")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sensoryFeedback(trigger: state.pendingDeletion) { _, pending in pending ? .warning : .success }
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
            .confirmationDialog("Delete your Chippy account?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
                Button("Delete My Account", role: .destructive) {
                    perform { try await environment.api.requestAccountDeletion() }
                }
            } message: {
                Text("Your account and everything in it will be permanently deleted in 7 days. You can cancel any time before then.")
            }
        }
        .summarySheetSize()
    }

    private var summary: String {
        if state.pendingDeletion, let date = state.deletionScheduledAt {
            return String(localized: "Everything will be permanently deleted on \(date.formatted(date: .long, time: .shortened)). You stay signed in until then and can keep your account at any time.")
        }
        return String(localized: "Your account is deleted 7 days after you ask, and you can cancel any time before then. After that it cannot be recovered.")
    }

    private func actionLabel(_ title: LocalizedStringKey) -> some View {
        HStack {
            Spacer()
            Text(title).fontWeight(.semibold)
            if isWorking { ProgressView().padding(.leading, 6) }
            Spacer()
        }
    }

    private func perform(_ work: @escaping () async throws -> AccountDeletionState) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                state = try await work()
            } catch let error as SummaryAPIError where error.code == "ACCOUNT_DELETION_SCOPE_REQUIRED" {
                // Sessions from before the app asked for `write:profile` need a fresh sign-in.
                errorMessage = String(localized: "Sign out and sign in again to confirm this change.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
