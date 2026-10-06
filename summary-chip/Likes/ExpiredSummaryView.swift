import SummaryKit
import SwiftUI

/// Opened from Likes (or a link) for someone else's summary or trip that can't be read anymore:
/// its share link expired or the owner made it private. Offers to remove it from Likes.
struct ExpiredSummaryView: View {
    let environment: AppEnvironment
    let summary: Summary
    @State private var isLiked: Bool
    @State private var isRemoving = false
    @State private var likeStatus: LikeStatus?
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, summary: Summary) {
        self.environment = environment
        self.summary = summary
        self._isLiked = State(initialValue: summary.isLiked)
    }

    var body: some View {
        ContentUnavailableView {
            Label("Link Expired", systemImage: "hourglass.bottomhalf.filled")
        } description: {
            Text("“\(summary.title)” can't be opened anymore. Its share link expired, or its owner made it private.")
        } actions: {
            if isLiked {
                Button("Remove from Likes", systemImage: "star.slash", role: .destructive) {
                    Task { await removeFromLikes() }
                }
                .buttonStyle(.bordered)
                .disabled(isRemoving)
                .accessibilityIdentifier("expired-remove-like")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.summaryGroupedBackground)
        .navigationTitle(summary.title)
        .summaryInlineNavigationTitle()
        .summaryHideTabBar()
        .overlay {
            if isRemoving {
                ProgressView("Removing from Likes…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .likeStatusOverlay($likeStatus)
        .accessibilityIdentifier("expired-summary")
    }

    private func removeFromLikes() async {
        isRemoving = true
        let (updated, status) = await environment.toggleLike(summary)
        isRemoving = false
        likeStatus = status
        guard !updated.isLiked else { return }
        isLiked = false
        // Let the confirmation show before leaving the page that no longer has a place in Likes.
        try? await Task.sleep(for: .seconds(0.9))
        dismiss()
    }
}
