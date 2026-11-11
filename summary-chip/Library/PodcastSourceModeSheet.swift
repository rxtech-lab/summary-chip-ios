import SummaryKit
import SwiftUI

struct PodcastSourceModeSheet: View {
    @Binding var mode: PodcastSourceMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    choice(.fullText, title: "Full Source", detail: "Use the saved original text and extract text from the uploaded PDF when available. Explain concepts, evidence, examples and caveats in detail.")
                    choice(.summary, title: "Chip Summaries", detail: "Use each chip’s summary and key points for a concise overview.")
                } footer: {
                    Text("Full Source requires saved source text. Choose Length for the approximate running time, and enable Plan Mode to review or expand the script before generating audio. Scanned PDFs need readable text. Very long documents may require fewer sources or an audiobook.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Source Content")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sensoryFeedback(.selection, trigger: mode)
        }
        .summarySheetFrame(minWidth: 320, idealWidth: 520, minHeight: 400)
        .presentationDetents([.large])
    }

    private func choice(_ value: PodcastSourceMode, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        Button { mode = value } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: mode == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(mode == value ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}
