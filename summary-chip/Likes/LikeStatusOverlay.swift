import SummaryKit
import SwiftUI

/// The outcome of starring or unstarring a summary, shown briefly over the screen.
struct LikeStatus: Identifiable, Equatable {
    enum Outcome: Equatable { case liked, unliked, failed(String) }

    let id = UUID()
    let outcome: Outcome

    var title: String {
        switch outcome {
        case .liked: String(localized: "Added to Likes")
        case .unliked: String(localized: "Removed from Likes")
        case .failed: String(localized: "Couldn't update Likes")
        }
    }

    var systemImage: String {
        switch outcome {
        case .liked: "star.fill"
        case .unliked: "star.slash"
        case .failed: "exclamationmark.triangle"
        }
    }

    var isFailure: Bool {
        if case .failed = outcome { true } else { false }
    }
}

extension View {
    /// Shows `status` as a capsule at the bottom of the screen for a moment, with haptic feedback.
    /// `.top` for screens whose bottom is covered (the trip diary's sheet on iPhone).
    func likeStatusOverlay(_ status: Binding<LikeStatus?>, edge: VerticalEdge = .bottom) -> some View {
        modifier(LikeStatusOverlay(status: status, edge: edge))
    }
}

private struct LikeStatusOverlay: ViewModifier {
    @Binding var status: LikeStatus?
    let edge: VerticalEdge

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if let status {
                    Label(status.title, systemImage: status.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                        .padding(edge == .top ? .top : .bottom, edge == .top ? 8 : 24)
                        .transition(.move(edge: edge == .top ? .top : .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("like-status")
                        .task(id: status.id) {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation { self.status = nil }
                        }
                }
            }
            .animation(.spring(duration: 0.35), value: status)
            .sensoryFeedback(trigger: status) { _, new in
                guard let new else { return nil }
                return new.isFailure ? .error : .success
            }
    }
}

/// Context-menu item that stars or unstars a summary.
struct LikeMenuButton: View {
    let summary: Summary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if summary.isLiked {
                Label("Remove from Likes", systemImage: "star.slash")
            } else {
                Label("Add to Likes", systemImage: "star")
            }
        }
    }
}

extension AppEnvironment {
    /// Flips the summary's star and reports the outcome for `likeStatusOverlay`.
    func toggleLike(_ summary: Summary) async -> (Summary, LikeStatus) {
        let liked = !summary.isLiked
        do {
            let updated = try await setLiked(summary, liked)
            return (updated, LikeStatus(outcome: liked ? .liked : .unliked))
        } catch {
            return (summary, LikeStatus(outcome: .failed(error.localizedDescription)))
        }
    }
}
