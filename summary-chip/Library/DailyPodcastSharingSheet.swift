import SummaryKit
import SwiftUI

/// Publishes an episode the way chips are shared: through any number of share links, each with its
/// own name and expiry, created, edited and deleted from the same screens as a chip's links.
struct DailyPodcastSharingSheet: View {
    let api: SummaryAPIClient
    let podcast: DailyPodcast
    @Environment(\.dismiss) private var dismiss
    @State private var links: [SummaryShareLink] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ShareLinksView(store: .podcast(api: api, podcast: podcast), links: $links)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(loading)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .overlay {
                    if loading {
                        ProgressView("Loading links…")
                            .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .alert("Couldn't Load Links", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
                .task { await load() }
                .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 420, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private func load() async {
        defer { loading = false }
        do {
            links = try await api.podcastShareLinks(key: podcast.key)
        } catch { self.error = error.localizedDescription }
    }
}
