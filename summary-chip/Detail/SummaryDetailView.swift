import SummaryKit
import SwiftUI

struct SummaryDetailView: View {
    let environment: AppEnvironment
    /// False when already shown inside a summary chat sheet.
    var allowsChat = true
    /// Called with the summary after it changes here (starred, edited), for callers holding a copy.
    var onUpdate: ((Summary) -> Void)?
    @State private var summary: Summary
    @State private var showsChat = false
    @State private var showsShare = false
    @State private var showsEditSharing = false
    @State private var showsRegenerate = false
    @State private var showsLanguage = false
    @State private var showsLocalFile = false
    @State private var showsSourceText = false
    @State private var confirmsDelete = false
    @State private var didDelete = false
    @State private var savedCount = 0
    @State private var showsNavigationTitle = false
    @State private var isTogglingLike = false
    @State private var likeStatus: LikeStatus?
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, summary: Summary, allowsChat: Bool = true, onUpdate: ((Summary) -> Void)? = nil) {
        self.environment = environment
        self.allowsChat = allowsChat
        self.onUpdate = onUpdate
        self._summary = State(initialValue: summary)
    }

    var body: some View {
        ScrollView {
            SummaryDetailContent(
                summary: summary,
                onEditSharing: summary.isOwner ? { showsEditSharing = true } : nil,
                onChangeLanguage: summary.isOwner ? { showsLanguage = true } : nil
            )
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
            // Ask on its own; like and share together; everything else waits in "More".
            if allowsChat {
                ToolbarItem(placement: .summaryTrailing) {
                    Button {
                        showsChat = true
                    } label: {
                        Label("Ask About This", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("ask-summary")
                }
                ToolbarSpacer(.fixed, placement: .summaryTrailing)
            }
            ToolbarItemGroup(placement: .summaryTrailing) {
                Button {
                    Task { await toggleLike() }
                } label: {
                    Label(summary.isLiked ? "Remove from Likes" : "Add to Likes",
                          systemImage: summary.isLiked ? "star.fill" : "star")
                }
                .disabled(isTogglingLike)
                .accessibilityIdentifier("summary-like")
                Button {
                    showsShare = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-summary")
            }
            moreToolbarActions
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
        .sheet(isPresented: $showsLanguage) {
            DisplayLanguageSheet(api: environment.api, summary: summary) { updated in saved(updated) }
        }
        .sheet(isPresented: $showsRegenerate) {
            RegenerateImageSheet(api: environment.api, summary: summary) { updated in saved(updated) }
        }
        .sheet(isPresented: $showsSourceText) {
            SourceMarkdownSheet(
                api: environment.api,
                summary: summary,
                onLanguageChanged: summary.isOwner ? { updated in apply(updated) } : nil
            )
        }
        .sheet(isPresented: $showsLocalFile) {
            LocalFileSheet(summaryID: summary.id)
        }
        .sheet(isPresented: $confirmsDelete) {
            DeleteSummarySheet(api: environment.api, summary: summary) {
                try? LocalFileStore().remove(summaryID: summary.id)
                environment.library.remove(id: summary.id)
                environment.likes.remove(id: summary.id)
                didDelete = true
                dismiss()
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: showsSourceText) { _, new in new }
        .sensoryFeedback(.success, trigger: savedCount)
        .sensoryFeedback(.success, trigger: didDelete) { _, new in new }
        .task(id: summary.id) { await refresh() }
        .task(id: summary.sourceMarkdownPending) { await pollSourceMarkdown() }
        .task(id: summary.translationPending) { await pollTranslation() }
        .sensoryFeedback(.success, trigger: summary.hasSourceMarkdown) { old, new in !old && new }
        .likeStatusOverlay($likeStatus)
        .onChange(of: summary) { _, updated in onUpdate?(updated) }
    }

    /// On iOS 27 these join the system overflow menu; elsewhere they get their own "More" menu.
    @ToolbarContentBuilder
    private var moreToolbarActions: some ToolbarContent {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            ToolbarOverflowMenu { moreActions }
        } else {
            moreActionsMenu
        }
        #else
        moreActionsMenu
        #endif
    }

    private var moreActionsMenu: some ToolbarContent {
        ToolbarItem(placement: .summaryTrailing) {
            Menu {
                moreActions
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("summary-more")
        }
    }

    @ViewBuilder
    private var moreActions: some View {
        if summary.hasSourceMarkdown {
            Button { showsSourceText = true } label: {
                Label("Source Text", systemImage: "doc.plaintext")
            }
            .accessibilityIdentifier("summary-source-text")
        } else if summary.sourceMarkdownPending {
            Button {} label: {
                Label("Formatting the source text…", systemImage: "doc.plaintext")
            }
            .disabled(true)
            .accessibilityIdentifier("summary-source-text-pending")
        }
        Button { showsLocalFile = true } label: {
            Label("Local File", systemImage: "doc.badge.gearshape")
        }
        .accessibilityIdentifier("summary-local-file")
        if summary.isOwner {
            Divider()
            Button {
                showsEditSharing = true
            } label: {
                Label("Edit sharing…", systemImage: "globe")
            }
            Button {
                showsLanguage = true
            } label: {
                Label("Language…", systemImage: "translate")
            }
            .accessibilityIdentifier("summary-language")
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
        }
    }

    private func apply(_ updated: Summary) {
        summary = updated
        environment.library.upsert(updated)
        environment.likes.upsert(updated)
    }

    /// The star flips at once; it flips back if the server refuses.
    private func toggleLike() async {
        let original = summary
        isTogglingLike = true
        summary.likedAt = original.isLiked ? nil : .now
        let (updated, status) = await environment.toggleLike(original)
        summary.likedAt = updated.likedAt
        isTogglingLike = false
        likeStatus = status
    }

    /// A sheet's edit went through; the sheet dismisses itself, so the feedback fires here.
    private func saved(_ updated: Summary) {
        apply(updated)
        savedCount += 1
    }

    /// The server writes the source document after the summary is returned; check back until it lands.
    private func pollSourceMarkdown() async {
        while summary.isOwner, summary.sourceMarkdownPending, !summary.hasSourceMarkdown {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            await refresh()
        }
    }

    /// Opened from a library page whose translation was still being written: fetch it once it lands.
    private func pollTranslation() async {
        var attempts = 0
        while summary.translationPending, attempts < 8 {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            attempts += 1
            await refresh()
        }
    }

    /// Others' summaries are refreshed only while their translation is pending; the copy opened is otherwise current.
    private func refresh() async {
        guard summary.isOwner || summary.translationPending,
              let fresh = try? await environment.api.summary(id: summary.id) else { return }
        apply(fresh)
    }

}

/// The page a library item opens: a trip diary for trips, the summary detail otherwise.
struct SummaryDestination: View {
    let environment: AppEnvironment
    let summary: Summary
    var allowsChat = true
    var onOpenTrip: ((Summary) -> Void)?
    var onUpdate: ((Summary) -> Void)?

    var body: some View {
        if summary.kind == .trip {
            TripDetailView(
                environment: environment,
                tripID: summary.id,
                title: summary.title,
                onOpenTrip: onOpenTrip.map { action in { action(summary) } }
            )
        } else {
            SummaryDetailView(environment: environment, summary: summary, allowsChat: allowsChat, onUpdate: onUpdate)
        }
    }
}

/// Loads a summary by id, then shows its detail (chat result cards, "Open in app").
struct SummaryLoaderView: View {
    let environment: AppEnvironment
    let id: String
    var allowsChat = true
    var onOpenTrip: ((Summary) -> Void)?
    @State private var summary: Summary?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let summary {
                SummaryDestination(environment: environment, summary: summary, allowsChat: allowsChat, onOpenTrip: onOpenTrip)
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

/// Presented for universal links (`/s/<slug>`), `summarychip://summary/<id>` and `summarychip://trip/<id>`.
/// "Open in Library" closes the sheet and shows the item in the main navigation via `onOpen`.
struct DeepLinkSheet: View {
    let environment: AppEnvironment
    let route: AppRoute
    var onOpen: ((Summary) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var summary: Summary?
    @State private var expiredLike: Summary?
    @State private var errorMessage: String?
    @State private var openCount = 0

    var body: some View {
        NavigationStack {
            Group {
                if case .tripID(let id) = route {
                    TripDetailView(environment: environment, tripID: id, title: summary?.title ?? "")
                } else if let summary {
                    // Keep the copy current so "Open in Library" carries a star made here.
                    SummaryDestination(environment: environment, summary: summary, onUpdate: { self.summary = $0 })
                } else if let expiredLike {
                    ExpiredSummaryView(environment: environment, summary: expiredLike)
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
                if let onOpen, let summary {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            openCount += 1
                            onOpen(summary)
                        } label: {
                            Label(summary.kind == .trip ? "Open Trip" : "Open in Library", systemImage: "arrow.up.right.square")
                        }
                        .help(summary.kind == .trip ? "Open Trip" : "Open in Library")
                        .accessibilityIdentifier("deep-link-open")
                    }
                }
            }
        }
        .task(id: route) { await load() }
        .sensoryFeedback(.impact(weight: .light), trigger: openCount)
    }

    private func load() async {
        if case .tripID(let id) = route {
            // The diary loads itself; its library item is only needed to open it in the Library.
            summary = environment.library.items.first { $0.id == id } ?? environment.likes.items.first { $0.id == id }
            if summary == nil { summary = try? await environment.api.summary(id: id) }
            return
        }
        do {
            let fresh: Summary
            switch route {
            case .slug(let slug):
                // Records the view (it then appears in the library as "Viewed") and returns the summary.
                fresh = try await environment.api.recordView(slug: slug)
            case .summaryID(let id), .tripID(let id):
                fresh = try await environment.api.summary(id: id)
            }
            environment.library.upsert(fresh)
            environment.likes.upsert(fresh)
            summary = fresh
        } catch let error as SummaryAPIError where error.isNotFound {
            if let saved { environment.library.remove(id: saved.id) }
            // A summary in Likes stays there after its link expires; show it as expired.
            if var liked = likedCopy {
                liked.isExpired = true
                expiredLike = liked
            } else {
                errorMessage = String(localized: "This summary is private, its link has expired, or it was deleted.")
            }
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
        case .summaryID(let id), .tripID(let id): environment.library.offline.summary(id: id)
        }
    }

    private var likedCopy: Summary? {
        switch route {
        case .slug(let slug): environment.likes.items.first { $0.slug == slug }
        case .summaryID(let id), .tripID(let id): environment.likes.items.first { $0.id == id }
        }
    }
}
