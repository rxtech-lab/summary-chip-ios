import AgentMarkdownUI
import RichDocumentEditor
import SummaryKit
import SwiftUI

/// The same composer for todo descriptions and rich documents; cancelling never mutates the host.
struct MarkdownEditorSheet: View {
    let api: SummaryAPIClient
    @State var markdown: String
    let onSave: (String) -> Void
    @State private var preview = false
    @State private var uploading = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if preview {
                    ScrollView {
                        MarkdownView(text: markdown, baseURL: nil).padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    RichMarkdownEditor(markdown: $markdown, onUploadingChanged: { uploading = $0 }) { data, filename, mime, progress in
                        try await api.uploadDocumentImage(data: data, filename: filename, mimeType: mime, progress: progress)
                    }
                }
            }
            .navigationTitle("Description")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(uploading) }
                ToolbarItem(placement: .primaryAction) {
                    Button(preview ? "Edit" : "Preview", systemImage: preview ? "pencil" : "eye") { preview.toggle() }.disabled(uploading)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onSave(markdown); dismiss() }.disabled(uploading) }
            }
        }
        .summarySheetSize()
    }
}
