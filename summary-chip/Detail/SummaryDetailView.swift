import SummaryKit
import SwiftUI

struct SummaryDetailView: View {
    let environment: AppEnvironment
    /// False when already shown inside a summary chat sheet.
    var allowsChat = true
    @State private var summary: Summary
    @State private var showsChat = false
    @State private var showsShare = false
    @State private var showsEditSharing = false
    @State private var showsRegenerate = false
    @State private var showsLocalFile = false
    @State private var confirmsDelete = false
    @State private var didDelete = false
    @State private var savedCount = 0
    @State private var showsNavigationTitle = false
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, summary: Summary, allowsChat: Bool = true) {
        self.environment = environment
        self.allowsChat = allowsChat
        self._summary = State(initialValue: summary)
    }

    var body: some View {
        ScrollView {
            SummaryDetailContent(summary: summary, onEditSharing: summary.isOwner ? { showsEditSharing = true } : nil)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(Color.summaryGroupedBackground)
        // The content carries a large title; show it in the bar once the hero and title scroll away.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let width = min(geometry.containerSize.width, 760) - 32
            let titleBottom = width / SummaryOGImage.aspectRatio + 120
            return geometry.contentOffset.y + geometry.contentInsets.top > titleBottom
        } action: { _, isPast in
            withAnimation(.easeInOut(duration: 0.2)) { showsNavigationTitle = isPast }
        }
        .navigationTitle(showsNavigationTitle ? summary.title : "")
        .summaryInlineNavigationTitle()
        .summaryHideTabBar()
        .toolbar {
            if allowsChat {
                ToolbarItem(placement: .summaryTrailing) {
                    Button {
                        showsChat = true
                    } label: {
                        Label("Ask About This", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("ask-summary")
                }
            }
            ToolbarItem(placement: .summaryTrailing) {
                Button { showsLocalFile = true } label: {
                    Label("Local File", systemImage: "doc.badge.gearshape")
                }
                .accessibilityIdentifier("summary-local-file")
            }
            ToolbarItem(placement: .summaryTrailing) {
                Button {
                    showsShare = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-summary")
            }
            if summary.isOwner {
                ToolbarItem(placement: .summaryTrailing) {
                    Menu {
                        Button {
                            showsEditSharing = true
                        } label: {
                            Label("Edit sharing…", systemImage: "globe")
                        }
                        Button {
                            showsRegenerate = true
                        } label: {
                            Label("Regenerate image…", systemImage: "photo.badge.arrow.down")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmsDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $showsChat) {
            ChatView(environment: environment, summary: summary)
        }
        .sheet(isPresented: $showsShare) {
            ShareModeSheet(summary: summary)
        }
        .sheet(isPresented: $showsEditSharing) {
            EditSharingSheet(api: environment.api, summary: summary) { updated in saved(updated) }
        }
        .sheet(isPresented: $showsRegenerate) {
            RegenerateImageSheet(api: environment.api, summary: summary) { updated in saved(updated) }
        }
        .sheet(isPresented: $showsLocalFile) {
            LocalFileSheet(summaryID: summary.id)
        }
        .sheet(isPresented: $confirmsDelete) {
            DeleteSummarySheet(api: environment.api, summary: summary) {
                try? LocalFileStore().remove(summaryID: summary.id)
                environment.library.remove(id: summary.id)
                didDelete = true
                dismiss()
            }
        }
        .sensoryFeedback(.success, trigger: savedCount)
        .sensoryFeedback(.success, trigger: didDelete) { _, new in new }
        .task(id: summary.id) { await refresh() }
    }

    private func apply(_ updated: Summary) {
        summary = updated
        environment.library.upsert(updated)
    }

    /// A sheet's edit went through; the sheet dismisses itself, so the feedback fires here.
    private func saved(_ updated: Summary) {
        apply(updated)
        savedCount += 1
    }

    private func refresh() async {
        guard summary.isOwner, let fresh = try? await environment.api.summary(id: summary.id) else { return }
        apply(fresh)
    }

}

/// Loads a summary by id, then shows its detail (chat result cards, "Open in app").
struct SummaryLoaderView: View {
    let environment: AppEnvironment
    let id: String
    var allowsChat = true
    @State private var summary: Summary?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let summary {
                SummaryDetailView(environment: environment, summary: summary, allowsChat: allowsChat)
            } else if let errorMessage {
                ContentUnavailableView("Summary unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .task(id: id) {
            do {
                let fresh = try await environment.api.summary(id: id)
                environment.library.upsert(fresh)
                summary = fresh
            } catch let error as SummaryAPIError where error.isNotFound {
                environment.library.remove(id: id)
                errorMessage = error.localizedDescription
            } catch {
                // Offline (or the server is down): show the copy saved on this device.
                if let saved = environment.library.offline.summary(id: id) {
                    summary = saved
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// Presented for universal links (`/s/<slug>`) and `summarychip://summary/<id>`.
struct DeepLinkSheet: View {
    let environment: AppEnvironment
    let route: AppRoute
    @Environment(\.dismiss) private var dismiss
    @State private var summary: Summary?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    SummaryDetailView(environment: environment, summary: summary)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Summary unavailable", systemImage: "link.badge.plus")
                    } description: {
                        Text(errorMessage)
                    }
                } else {
                    ProgressView("Opening summary…")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: route) { await load() }
    }

    private func load() async {
        do {
            let fresh: Summary
            switch route {
            case .slug(let slug):
                // Records the view (it then appears in the library as "Viewed") and returns the summary.
                fresh = try await environment.api.recordView(slug: slug)
            case .summaryID(let id):
                fresh = try await environment.api.summary(id: id)
            }
            environment.library.upsert(fresh)
            summary = fresh
        } catch let error as SummaryAPIError where error.isNotFound {
            if let saved { environment.library.remove(id: saved.id) }
            errorMessage = "This summary is private, its link has expired, or it was deleted."
        } catch {
            // Offline (or the server is down): show the copy saved on this device.
            if let saved {
                summary = saved
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var saved: Summary? {
        switch route {
        case .slug(let slug): environment.library.offline.summary(slug: slug)
        case .summaryID(let id): environment.library.offline.summary(id: id)
        }
    }
}
