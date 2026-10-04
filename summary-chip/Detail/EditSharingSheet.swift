import SummaryKit
import SwiftUI

/// Dedicated sheet for changing visibility and link lifetime (`PATCH /api/v1/summaries/:id`).
struct EditSharingSheet: View {
    let api: SummaryAPIClient
    let summary: Summary
    let onSaved: (Summary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var visibility: SummaryVisibility
    @State private var ttl: TTLOption
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(api: SummaryAPIClient, summary: Summary, onSaved: @escaping (Summary) -> Void) {
        self.api = api
        self.summary = summary
        self.onSaved = onSaved
        self._visibility = State(initialValue: summary.visibility)
        self._ttl = State(initialValue: TTLOption(ttlDays: summary.ttlDays))
    }

    private var ttlChanged: Bool { ttl != TTLOption(ttlDays: summary.ttlDays) }
    private var hasChanges: Bool { visibility != summary.visibility || ttlChanged }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    currentStatus
                } header: {
                    Text("Current status")
                }
                SharingOptionsSections(visibility: $visibility, ttl: $ttl)
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Sharing")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!hasChanges)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
        .summarySheetSize()
    }

    private var currentStatus: some View {
        let isPublic = summary.visibility == .public
        return HStack(spacing: 14) {
            Image(systemName: summary.visibility.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isPublic ? .green : .orange)
                .frame(width: 44, height: 44)
                .background((isPublic ? Color.green : Color.orange).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                (isPublic ? Text("Public link") : Text("Private"))
                    .font(.headline)
                if isPublic {
                    ExpiryLabel(summary.expiresAt)
                } else {
                    Text("Link disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let patch = SummaryPatch(
            visibility: visibility != summary.visibility ? visibility : nil,
            ttl: ttlChanged ? ttl : nil
        )
        do {
            let updated = try await api.updateSummary(id: summary.id, patch: patch)
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
