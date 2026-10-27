import SummaryKit
import SwiftUI

struct PodcastSummarySheet: View {
    let api: SummaryAPIClient
    let podcast: DailyPodcast
    let onUpdated: (DailyPodcast) -> Void
    @State private var generatedSummary: String?
    @State private var generating = false
    @State private var error: String?
    @State private var successes = 0
    @State private var attempts = 0

    private var summary: String? { generatedSummary ?? podcast.summary }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(podcast.title).font(.title2.bold())
                    if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if podcast.language != podcast.sourceLanguage {
                            Text(PodcastLanguagesSheet.title(for: podcast.sourceLanguage))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(summary).textSelection(.enabled)
                            .accessibilityIdentifier("podcast-summary-text")
                    } else {
                        Text("A summary will be generated from this episode’s transcript.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Podcast Summary")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .overlay {
            if generating {
                ProgressView("Generating summary…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: attempts) { await generateIfNeeded() }
        .alert("Couldn’t Generate Summary", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Retry") { error = nil; attempts += 1 }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: { Text(error ?? "") }
        .sensoryFeedback(.success, trigger: successes)
        .sensoryFeedback(.selection, trigger: attempts)
        .sensoryFeedback(.error, trigger: error)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 400, maxHeight: .infinity)
        #endif
        .presentationDetents([.large])
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
    }
    private func generateIfNeeded() async {
        guard summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false, !generating else { return }
        generating = true
        defer { generating = false }
        do {
            let updated = try await api.generatePodcastSummary(podcast)
            generatedSummary = updated.summary
            onUpdated(updated)
            successes += 1
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
