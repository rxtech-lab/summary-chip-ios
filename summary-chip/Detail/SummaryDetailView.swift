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
    @State private var showsNewPodcast = false
    @State private var linkedPodcasts: [DailyPodcast] = []
    @State private var showsLinkedPodcasts = false
    @State private var selectedPodcast: DailyPodcast?
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
    @State private var versions: DocumentVersionsModel
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, summary: Summary, allowsChat: Bool = true, onUpdate: ((Summary) -> Void)? = nil) {
        self.environment = environment
        self.allowsChat = allowsChat
        self.onUpdate = onUpdate
        self._summary = State(initialValue: summary)
        self._versions = State(initialValue: DocumentVersionsModel(api: environment.api, id: summary.id))
    }

    /// The summary on screen: a past version's text while one is picked in the toolbar, read-only.
    private var shown: Summary {
        if case .summary(let content) = versions.preview?.content { return summary.showing(content) }
        return summary
    }

    private var isPreviewingVersion: Bool { versions.isPreviewing }

    var body: some View {
        ScrollView {
            SummaryDetailContent(
                summary: shown,
                onEditSharing: summary.isOwner && !isPreviewingVersion ? { showsEditSharing = true } : nil,
                onChangeLanguage: summary.isOwner && !isPreviewingVersion ? { showsLanguage = true } : nil
            )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(Color.summaryGroupedBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VersionPreviewBanner(model: versions)
        }
        // The content carries a large title; show it in the bar once the hero and title scroll away.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let width = min(geometry.containerSize.width, 760) - 32
            let titleBottom = width / SummaryOGImage.aspectRatio + 120
            return geometry.contentOffset.y + geometry.contentInsets.top > titleBottom
        } action: { _, isPast in
            withAnimation(.easeInOut(duration: 0.2)) { showsNavigationTitle = isPast }
        }
        .navigationTitle(showsNavigationTitle ? shown.title : "")
        .summaryInlineNavigationTitle()
        .summaryHideTabBar()
        .toolbar {
            if !linkedPodcasts.isEmpty {
                ToolbarItem(placement: .summaryTrailing) {
                    Button { showsLinkedPodcasts = true } label: {
                        Label("Watch Podcast", systemImage: "play.rectangle")
                    }
                    .accessibilityIdentifier("summary-linked-podcasts")
                }
            }
            ToolbarItem(placement: .summaryTrailing) {
                Button {
                    Task { await toggleLike() }
                } label: {
                    Label(summary.isLiked ? "Remove from Likes" : "Add to Likes",
                          systemImage: summary.isLiked ? "star.fill" : "star")
                }
                .disabled(isTogglingLike)
                .accessibilityIdentifier("summary-like")
            }
            moreToolbarActions
        }
        .sheet(isPresented: $showsLinkedPodcasts, onDismiss: {
            if let podcast = selectedPodcast {
                selectedPodcast = nil
                environment.podcastPlayer.present(podcast: podcast)
            }
        }) {
            LinkedPodcastsSheet(podcasts: linkedPodcasts) { podcast in
                selectedPodcast = podcast
                showsLinkedPodcasts = false
            }
        }
        .sheet(isPresented: $showsChat) {
            ChatView(environment: environment, summary: summary)
        }
        .sheet(isPresented: $showsShare) {
            ShareModeSheet(summary: summary, api: environment.api) { updated in apply(updated) }
        }
        .sheet(isPresented: $showsEditSharing) {
            EditSharingSheet(api: environment.api, summary: summary) { updated in saved(updated) }
        }
        .sheet(isPresented: $showsLanguage) {
            DisplayLanguageSheet(api: environment.api, summary: summary) { updated in saved(updated) }
        }
        .sheet(isPresented: $showsNewPodcast) {
            DailyPodcastGenerationSheet(api: environment.api, date: Date(), existing: nil, library: true, initialChip: summary) { podcast in
                Task {
                    if let id = podcast.summaryId, let chip = try? await environment.api.summary(id: id) {
                        environment.library.insert(chip)
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                    environment.podcastPlayer.present(podcast: podcast)
                }
            }
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
        .sensoryFeedback(.selection, trigger: showsLinkedPodcasts)
        .sensoryFeedback(.selection, trigger: showsNewPodcast)
        .task(id: summary.id) { await reloadLinkedPodcasts() }
        .onChange(of: showsNewPodcast) { _, shown in
            if !shown { Task { await reloadLinkedPodcasts() } }
        }
        .onChange(of: environment.podcastPlayer.isPresented) { _, shown in
            if !shown { Task { await reloadLinkedPodcasts() } }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: showsSourceText) { _, new in new }
        .sensoryFeedback(.success, trigger: savedCount)
        .sensoryFeedback(.success, trigger: didDelete) { _, new in new }
        .task(id: summary.id) { await refresh() }
        .task(id: summary.sourceMarkdownPending) { await pollSourceMarkdown() }
        .task(id: summary.translationPending) { await pollTranslation() }
        .sensoryFeedback(.success, trigger: summary.hasSourceMarkdown) { old, new in !old && new }
        .likeStatusOverlay($likeStatus)
        .documentVersions(versions) { restored in
            if let updated = restored.summary { apply(updated) }
        }
        .task(id: summary.isOwner) { if summary.isOwner { await versions.reload() } }
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
        if allowsChat {
            Button { showsChat = true } label: {
                Label("Ask About This", systemImage: "sparkles")
            }
            .accessibilityIdentifier("ask-summary")
            Divider()
        }
        Button {
            showsShare = true
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("share-summary")
        if !isPreviewingVersion {
            Button { showsNewPodcast = true } label: { Label("Create Podcast", systemImage: "waveform") }
                .accessibilityIdentifier("summary-create-podcast")
        }
        if summary.isOwner {
            // A submenu: pick a version to preview in place, restore it, or open the full history.
            VersionToolbarMenu(model: versions)
        }
        Divider()
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
        if summary.isOwner && !isPreviewingVersion {
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

    private func reloadLinkedPodcasts() async {
        do { linkedPodcasts = try await environment.api.linkedVideoPodcasts(summaryID: summary.id) }
        catch { linkedPodcasts = [] }
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
        Task { await versions.reload() }
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
        // An agent's edit elsewhere is a new version.
        if fresh.isOwner, fresh.updatedAt != summary.updatedAt { Task { await versions.reload() } }
        apply(fresh)
    }

}

/// The page a library item opens: a trip diary for trips, the LaTeX editor for papers, the summary detail otherwise.
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
        } else if summary.kind == .miniApp {
            MiniAppDetailView(environment: environment, appID: summary.id, title: summary.title)
        } else if summary.kind == .podcast {
            LibraryPodcastDetail(environment: environment, summary: summary)
        } else if summary.kind == .paper {
            PaperDetailView(environment: environment, paperID: summary.id, title: summary.title)
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
/// "Open in Feed" closes the sheet and shows the item in the main navigation via `onOpen`.
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
                    // Keep the copy current so "Open in Feed" carries a star made here.
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
                            Label(summary.kind == .trip ? "Open Trip" : summary.kind == .miniApp ? "Open Clip" : "Open in Feed", systemImage: "arrow.up.right.square")
                        }
                        .help(summary.kind == .trip ? "Open Trip" : summary.kind == .miniApp ? "Open Clip" : "Open in Feed")
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

private struct LibraryPodcastDetail: View {
    let environment: AppEnvironment
    let summary: Summary
    @State private var podcast: DailyPodcast?
    @State private var loading = true
    @State private var openingChip = false
    @State private var showsRegeneration = false
    @State private var showsLinkedChips = false
    @State private var pendingChipID: String?
    @State private var regenerations = 0
    @State private var error: String?
    var body: some View {
        Group {
            if let podcast {
                DailyPodcastPlaybackView(api: environment.api, podcast: podcast,
                    player: environment.podcastPlayer, onOpenChip: openChip)
            } else if !loading {
                ContentUnavailableView {
                    Label("Podcast Unavailable", systemImage: "waveform")
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if loading || openingChip {
                ProgressView(openingChip ? "Opening chip…" : "Loading podcast…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle(podcast?.title ?? summary.title)
        .toolbar {
            if let podcast, !podcast.sourceChipIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Linked Chips", systemImage: "doc.on.doc") { showsLinkedChips = true }
                        .accessibilityIdentifier("podcast-linked-chips")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Regenerate Podcast", systemImage: "arrow.clockwise") { showsRegeneration = true }
                    .help("Regenerate Podcast")
                    .disabled(podcast == nil)
                    .accessibilityIdentifier("library-podcast-regenerate")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Podcast Options", systemImage: "ellipsis") { environment.podcastPlayer.isPresented = true }
                    .disabled(podcast == nil)
            }
        }
        .sheet(isPresented: $showsLinkedChips, onDismiss: {
            if let id = pendingChipID { pendingChipID = nil; openChip(id) }
        }) {
            PodcastLinkedChipsSheet(api: environment.api, chipIDs: podcast?.sourceChipIDs ?? []) { id in
                pendingChipID = id
                showsLinkedChips = false
            }
        }
        .sensoryFeedback(.selection, trigger: showsLinkedChips)
        .sheet(isPresented: $showsRegeneration) {
            if let podcast {
                // Adds a new version to this chip; earlier versions stay in Manage Versions.
                DailyPodcastGenerationSheet(api: environment.api, date: environment.podcastPlayer.date ?? Date(), existing: podcast, library: true) { regenerated in
                    regenerations += 1
                    show(regenerated)
                    // The chip's title and cover are redrawn with the new version.
                    Task { if let chip = try? await environment.api.summary(id: summary.id) { environment.library.upsert(chip) } }
                }
            }
        }
        .sensoryFeedback(.success, trigger: regenerations)
        .task { await load() }
        .onDisappear {
            if environment.podcastPlayer.inlinePodcastKey == podcast?.key { environment.podcastPlayer.inlinePodcastKey = nil }
        }
        .alert("Couldn't Open Podcast", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func openChip(_ id: String) {
        openingChip = true
        Task {
            defer { openingChip = false }
            do { environment.pendingLibraryItem = try await environment.api.summary(id: id) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let saved = try await environment.api.libraryPodcast(summaryID: summary.id)
            try Task.checkCancellation()
            show(saved)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func show(_ saved: DailyPodcast) {
        podcast = saved
        environment.podcastPlayer.inlinePodcastKey = saved.key
        if environment.podcastPlayer.podcast?.key != saved.key || environment.podcastPlayer.podcast?.video?.id != saved.video?.id {
            environment.podcastPlayer.replace(saved)
            environment.podcastPlayer.date = saved.day.flatMap { ISO8601DateFormatter().date(from: $0.start) } ?? Date()
        }
    }
}


private struct LinkedPodcastsSheet: View {
    let podcasts: [DailyPodcast]
    let onSelect: (DailyPodcast) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var taps = 0

    var body: some View {
        NavigationStack {
            List(podcasts, id: \.key) { podcast in
                Button { taps += 1; onSelect(podcast) } label: {
                    HStack {
                        Image(systemName: "play.rectangle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(podcast.title).font(.headline)
                            Text(podcast.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                .accessibilityIdentifier("linked-podcast-\(podcast.key)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Watch Podcast")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sensoryFeedback(.selection, trigger: taps)
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}
