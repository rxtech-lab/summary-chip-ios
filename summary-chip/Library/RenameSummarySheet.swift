import SummaryKit
import SwiftUI

/// Edits the library title through the common endpoint for every document kind.
struct RenameSummarySheet: View {
    let api: SummaryAPIClient
    let summary: Summary
    let onRenamed: (Summary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(api: SummaryAPIClient, summary: Summary, onRenamed: @escaping (Summary) -> Void) {
        self.api = api
        self.summary = summary
        self.onRenamed = onRenamed
        _title = State(initialValue: summary.title)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTooLong: Bool { trimmedTitle.utf16.count > 200 }
    private var canSave: Bool {
        !isSaving && !trimmedTitle.isEmpty && !isTooLong && trimmedTitle != summary.title
    }

    var body: some View {
        Group {
            #if os(macOS)
            VStack(spacing: 0) {
                HStack {
                    Text("Rename Chip").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    cancelButton.keyboardShortcut(.cancelAction)
                    saveButton.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
                .padding(24)
                Divider()
                renameForm
            }
            .frame(maxHeight: .infinity)
            #else
            NavigationStack {
                renameForm
                    .navigationTitle("Rename Chip")
                    .summaryInlineNavigationTitle()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { cancelButton }
                        ToolbarItem(placement: .confirmationAction) { saveButton }
                    }
            }
            #endif
        }
        .summarySheetSize()
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .overlay {
            if isSaving { ActionStatusOverlay(String(localized: "Renaming…")) }
        }
        .statusAlert("Couldn't Rename Chip", message: errorMessage) { errorMessage = nil }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .onAppear { titleFocused = true }
    }

    private var renameForm: some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($titleFocused)
                    .accessibilityIdentifier("chip-rename-title")
            } footer: {
                if isTooLong {
                    Text("Use 200 characters or fewer.").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cancelButton: some View {
        Button("Cancel") { dismiss() }
            .disabled(isSaving)
    }

    private var saveButton: some View {
        Button("Save") { Task { await save() } }
            .disabled(!canSave)
            .accessibilityIdentifier("chip-rename-save")
    }

    private func save() async {
        guard canSave else { return }
        let newTitle = trimmedTitle
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await api.updateSummary(id: summary.id, patch: SummaryPatch(title: newTitle))
            onRenamed(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
