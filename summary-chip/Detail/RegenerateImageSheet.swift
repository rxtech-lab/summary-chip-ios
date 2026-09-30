import SummaryKit
import SwiftUI

/// Dedicated sheet for `POST /api/v1/summaries/:id/image`.
struct RegenerateImageSheet: View {
    let api: SummaryAPIClient
    let summary: Summary
    let onSaved: (Summary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var style: ImageStyle
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(api: SummaryAPIClient, summary: Summary, onSaved: @escaping (Summary) -> Void) {
        self.api = api
        self.summary = summary
        self.onSaved = onSaved
        self._style = State(initialValue: summary.imageStyle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SummaryOGImage(summary: summary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(isWorking ? 0.4 : 1)
                        .overlay { if isWorking { ProgressView("Designing…") } }
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } footer: {
                    Text("A new preview image replaces the current one. Links that were already shared show the new image once apps refresh their preview.")
                }
                Section("Style") {
                    Picker("Style", selection: $style) {
                        ForEach(ImageStyle.allCases) { style in
                            VStack(alignment: .leading) {
                                Text(style.title)
                                Text(style.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Regenerate Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Regenerate") { Task { await regenerate() } }
                        .fontWeight(.semibold)
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
    }

    private func regenerate() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await api.regenerateImage(id: summary.id, style: style)
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
