import SummaryKit
import SwiftUI

struct DeleteSummarySheet: View {
    let api: SummaryAPIClient
    let summary: Summary
    let onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            #if os(macOS)
            // Sheet navigation stacks don't display window-toolbar placements on macOS.
            // Keep these actions in the sheet's header so they always remain visible.
            VStack(spacing: 0) {
                macToolbar
                Divider()
                deletionForm
            }
            #else
            NavigationStack {
                deletionForm
                    .navigationTitle(deleteTitle)
                    .summaryInlineNavigationTitle()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }.disabled(isDeleting)
                        }
                    }
            }
            #endif
        }
        .summarySheetSize()
        .disabled(isDeleting)
        .overlay {
            if isDeleting {
                deletingOverlay
            }
        }
        .interactiveDismissDisabled(isDeleting)
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
    }

    private var deleteTitle: LocalizedStringKey {
        switch summary.kind {
        case .trip: "Delete Trip"
        case .paper: "Delete Paper"
        case .summary, .other: "Delete Summary"
        }
    }

    private var deleteMessage: LocalizedStringKey {
        switch summary.kind {
        case .trip: "The link and preview stop working and the trip is removed permanently. To only stop sharing, make it private instead."
        case .paper: "The link and preview stop working and the paper is removed permanently. To only stop sharing, make it private instead."
        case .summary, .other: "The link and preview stop working and the summary is removed permanently. To only stop sharing, make it private instead."
        }
    }

    private var deletingOverlay: some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
            HStack(spacing: 12) {
                ProgressView()
                Text("Deleting…")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .accessibilityIdentifier("delete-summary-progress")
    }

    private var deletionForm: some View {
        Form {
            Section {
                Text(summary.title).font(.headline)
                Text(deleteMessage)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            #if !os(macOS)
            Section {
                deleteButton
            }
            #endif
        }
        .formStyle(.grouped)
    }

    #if os(macOS)
    private var macToolbar: some View {
        HStack(spacing: 12) {
            Text(deleteTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 16)
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .disabled(isDeleting)
                .keyboardShortcut(.cancelAction)
            deleteButton
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .accessibilityIdentifier("delete-summary-toolbar")
    }
    #endif

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { await delete() }
        } label: {
            Label(deleteTitle, systemImage: "trash")
        }
        .disabled(isDeleting)
        .accessibilityIdentifier("confirm-delete-summary")
    }

    private func delete() async {
        guard !isDeleting else { return }
        errorMessage = nil
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await api.deleteSummary(id: summary.id)
            dismiss()
            onDeleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
