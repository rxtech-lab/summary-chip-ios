import SummaryKit
import SwiftUI

/// `New Document`: a title and Markdown that the server turns into blocks. Agents keep editing it over MCP.
struct NewRichDocumentSheet: View {
    let api: SummaryAPIClient
    let onCreated: (RichDocument) -> Void
    @State private var title = ""
    @State private var markdown = ""
    @State private var visibility: SummaryVisibility = .private
    @State private var isCreating = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).accessibilityIdentifier("new-rich-document-title")
                }
                Section {
                    TextEditor(text: $markdown)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("new-rich-document-markdown")
                } header: {
                    Text("Markdown")
                } footer: {
                    Text("Headings start new sections, and a line with only an image, video or audio link becomes a media block. Your agent can edit the document through Chippy's MCP server.")
                }
                Section {
                    Picker("Visibility", selection: $visibility) {
                        ForEach(SummaryVisibility.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Document")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isCreating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(isCreating || markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("new-rich-document-create")
                }
            }
            .overlay { if isCreating { ActionStatusOverlay(String(localized: "Creating document…")) } }
            .statusAlert("Couldn't Create Document", message: error) { error = nil }
            .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        }
        .interactiveDismissDisabled(isCreating)
        .summarySheetSize()
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        do {
            let document = try await api.createRichDocument(markdown: markdown, title: title.nilIfBlank, visibility: visibility)
            onCreated(document)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
