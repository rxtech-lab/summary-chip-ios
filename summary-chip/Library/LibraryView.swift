import SummaryKit
import SwiftUI

struct LibraryView: View {
    @State private var showingMarket = false
    @Bindable var environment: AppEnvironment
    @State private var feedScroll = SummaryFeedScrollState()
    @State private var didLoadInitially = false
    @State private var podcastTaps = 0
    @State private var showsFilters = false
    @State private var showsNewSummary = false
    @State private var showsNewTrip = false
    @State private var showsNewPaper = false
    @State private var showsNewGraph = false
    @State private var showsNewDocument = false
    @State private var showsViewedResumes = false
    @State private var selectedPublicationSlug: String?
    @State private var showsNewResume = false
    @State private var showsNewTodo = false
    @State private var showsNewMiniApp = false
    @State private var showsCredits = false
    @State private var sharingSummary: Summary?
    @State private var xSharingRequest: XSharingRequest?
    @State private var deletingSummary: Summary?
    @State private var renamingSummary: Summary?
    @State private var renamedCount = 0
    @State private var showsRenamedStatus = false
    @State private var deletedCount = 0
    @State private var likeStatus: LikeStatus?
    @State private var localPath: [Summary] = []
    @State private var model: LibraryModel
    @State private var deletingBook: AudiobookPlanSummary?
    @State private var deletingPlan: PodcastPlanSummary?
    @State private var planStatus: String?
    @State private var planError: String?
    @State private var planChanges = 0
    /// Lets a parent (the macOS sidebar layout) push a summary, e.g. one picked in search.
    var path: Binding<[Summary]>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSummarySearch) private var openSearch
    @Environment(\.openLibraryItem) private var openLibraryItem
    @Environment(\.chatPanelVisibility) private var chatPanelVisibility
    @Environment(\.openPodcast) private var openPodcast
    @Environment(\.openMiniApp) private var openMiniApp

    init(environment: AppEnvironment, path: Binding<[Summary]>? = nil, kind: SummaryKind? = nil) {
        self.environment = environment
        self.path = path
        _model = State(initialValue: kind == nil ? environment.library : LibraryModel(
            api: environment.api, offline: environment.library.offline, kind: kind
        ))
    }

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var isMiniApps: Bool { model.kind == .miniApp }
    /// Clips open full screen (or in their own window) rather than on this stack.
    private var stackPath: Binding<[Summary]> { (path ?? $localPath).presentingMiniApps(with: openMiniApp) }

    private var pointsTitle: String {
        environment.credits.points.map { $0.formatted() } ?? "–"
    }

    var body: some View {
        FeedNavigationContainer(environment: environment, path: stackPath) {
            sharingContent
        }
        .onReceive(NotificationCenter.default.publisher(for: .authorFollowingChanged)) { _ in
            Task { await model.reload() }
        }
        // Load with the navigation container, rather than reloading page one when detail is popped.
        .task {
            guard !didLoadInitially else { return }
            await model.reload()
            didLoadInitially = model.hasLoaded
        }
    }

    // Opaque view boundaries keep each presentation chain small enough to type-check independently.
    private var navigationContent: some View {
        feedSurface
            #if !os(visionOS)
            .navigationTitle(isMiniApps ? String(localized: "Clips") : String(localized: "Feed"))
            .navigationDestination(for: Summary.self) { summary in
                SummaryDestination(environment: environment, summary: summary)
                    .chatPanelToolbar()
            }
            #endif
            .refreshable { await model.reload() }
            .onChange(of: scenePhase) { _, phase in
                // Pick up summaries made elsewhere (share extension, web) whenever the app is reopened.
                guard phase == .active, model.hasLoaded else { return }
                Task { await model.reload() }
            }
            .onChange(of: path?.wrappedValue ?? localPath) { _, path in
                // Details update the shared library; refresh the dedicated tab when returning.
                if isMiniApps && path.isEmpty { Task { await model.reload() } }
            }
            #if !os(visionOS)
            .toolbar { libraryToolbar
                #if !os(macOS)
                ToolbarItem(placement: .primaryAction) { Button {
                    showingMarket = true
                } label: { Label("Discover", systemImage: "safari") } }
                #endif
            }
            #if !os(macOS)
            .sensoryFeedback(.selection, trigger: showingMarket)
            .fullScreenCover(isPresented: $showingMarket) { MarketplaceScreen(environment: environment) }
            #endif
            #endif
            .sensoryFeedback(.selection, trigger: podcastTaps)
    }

    @ViewBuilder
    private var feedSurface: some View {
        #if os(visionOS)
        VStack(alignment: .leading, spacing: 16) {
            Text(isMiniApps ? String(localized: "Clips") : String(localized: "Feed"))
                .font(.largeTitle.bold())
                .padding(.horizontal, 24)
            content
                .clipped()
        }
        .padding(.top, 24)
        // Reserve space outside the scroll viewport for the bottom ornament.
        .padding(.bottom, 80)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack(spacing: 16) {
                Button { showsCredits = true } label: {
                    Label("\(pointsTitle) pts", systemImage: "sparkles")
                }
                createButton
                if let openSearch { SummarySearchButton(action: openSearch) }
                Button("Filters", systemImage: "line.3.horizontal.decrease") { showsFilters = true }
                backgroundJobsButton
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reload() } }
            }
            .labelStyle(.iconOnly)
            .padding(12)
            .glassBackgroundEffect(in: Capsule())
        }
        #else
        content
        #endif
    }

    private func applyFilter(_ filter: LibraryFilter) {
        guard filter != model.filter else { return }
        feedScroll.reset()
        model.filter = filter
        Task { await model.reload() }
    }

    private var plannedPodcastsHeader: AnyView? {
        guard !isMiniApps, model.showsPlannedPodcasts,
              !model.plannedPodcasts.isEmpty || !model.plannedAudiobooks.isEmpty || !model.audiobookJobs.isEmpty else { return nil }
        return AnyView(VStack(spacing: 0) {
            if (model.kind ?? model.filter.kind) != .podcast, !model.audiobookJobs.isEmpty || !model.plannedAudiobooks.isEmpty {
                AudiobooksStrip(jobs: model.audiobookJobs, plans: model.plannedAudiobooks, onOpenJob: { podcastTaps += 1; environment.libraryCreation = .audiobookJob($0) },
                                onOpenPlan: openBook, onDeletePlan: { deletingBook = $0 })
                    .task(id: model.audiobookJobs.filter { $0.status == "running" }.count) { await model.followAudiobookJobs() }
            }
            if (model.kind ?? model.filter.kind) != .audiobook, !model.plannedPodcasts.isEmpty {
                PlannedPodcastsStrip(plans: model.plannedPodcasts, onOpen: openPlan, onDelete: { deletingPlan = $0 })
            }
        })
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView(isMiniApps ? String(localized: "Loading your clips…") : String(localized: "Loading your summaries…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            VStack(spacing: 0) {
                plannedPodcastsHeader
                LibraryEmptyState(model: model, isMiniApps: isMiniApps, createClip: { showsNewMiniApp = true },
                                  createSummary: { showsNewSummary = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // Clips are a plain grid; only the Feed is grouped by day with a timeline.
            SummaryCardFeed(entries: model.entries, scrollState: feedScroll, editorPickIDs: model.editorPickIDs, showsTimeline: !isMiniApps, showsDateHeaders: !isMiniApps, header: plannedPodcastsHeader, onReachEnd: {
                Task { await model.loadMore() }
            }, onSelect: { summary in
                if (summary.kind == .podcast || summary.kind == .audiobook), let openPodcast { openPodcast(summary) }
                else { stackPath.wrappedValue.append(summary) }
            }, onPlayDay: { day in
                podcastTaps += 1
                environment.podcastPlayer.present(date: day)
            }, menuItems: { summary in
                LikeMenuButton(summary: summary) {
                    Task {
                        let result = await environment.toggleLike(summary)
                        likeStatus = result.1
                        if isMiniApps { model.upsert(result.0) }
                    }
                }
                if summary.kind == .resume {
                    Button("Open Résumé", systemImage: "person.text.rectangle") { stackPath.wrappedValue.append(summary) }
                } else {
                Menu {
                    Button { sharingSummary = summary } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button("Share to X", systemImage: "arrow.up.forward") {
                        xSharingRequest = XSharingRequest(summary: summary)
                    }
                    .accessibilityIdentifier("chip-share-x")
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                }
                if summary.isOwner {
                    Divider()
                    Button {
                        podcastTaps += 1
                        renamingSummary = summary
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("chip-rename")
                    Button(role: .destructive) {
                        deletingSummary = summary
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }) {
                if model.isLoadingMore {
                    ProgressView().padding()
                } else if model.isOffline {
                    Label("You're offline. Showing summaries saved on this device.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                } else if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).padding()
                }
            }
            #if !os(visionOS)
            .background(Color.summaryGroupedBackground)
            #endif
        }
    }
}

private extension LibraryView {
    var creationContent: some View {
        navigationContent
            .sheet(isPresented: $showsFilters) {
                LibraryFilterSheet(model: model) { applyFilter($0) }
            }
            .sheet(isPresented: $showsNewSummary) {
                NewSummarySheet(environment: environment)
            }
            .sheet(isPresented: $showsNewTrip) {
                NewTripSheet(api: environment.api) { trip in
                    Task {
                        guard let summary = await environment.libraryItem(forCreated: trip) else { return }
                        // Let the sheet finish dismissing before pushing.
                        try? await Task.sleep(for: .milliseconds(350))
                        stackPath.wrappedValue.append(summary)
                    }
                }
            }
            .sheet(isPresented: $showsNewMiniApp) {
                NewMiniAppSheet(environment: environment) { app in
                    Task {
                        guard let summary = try? await environment.api.summary(id: app.id) else { return }
                        environment.library.upsert(summary)
                        if isMiniApps { model.insert(summary) }
                        try? await Task.sleep(for: .milliseconds(350))
                        if !isMiniApps, let openLibraryItem {
                            openLibraryItem(summary)
                            return
                        }
                        stackPath.wrappedValue.append(summary)
                    }
                }
            }
    }

    var podcastContent: some View {
        creationContent
            .confirmationDialog("Delete this planned audiobook?", isPresented: Binding(get: { deletingBook != nil }, set: { if !$0 { deletingBook = nil } }),
                                titleVisibility: .visible, presenting: deletingBook) { book in
                Button("Delete Plan", role: .destructive) { deleteBook(book) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("The plan and its drawn scenes are removed. No audiobook has been made from it.") }
    }

    func openBook(_ summary: AudiobookPlanSummary) {
        podcastTaps += 1
        planStatus = String(localized: "Opening plan…")
        Task {
            do { environment.libraryCreation = .resumedAudiobook(try await environment.api.audiobookPlan(id: summary.id)) }
            catch {
                planError = error.localizedDescription
                refreshPlans()
            }
            planStatus = nil
        }
    }

    func deleteBook(_ book: AudiobookPlanSummary) {
        planStatus = String(localized: "Deleting plan…")
        Task {
            do {
                try await environment.api.deleteAudiobookPlan(id: book.id)
                withAnimation { model.removePlannedPodcast(id: book.id) }
                planChanges += 1
            } catch { planError = error.localizedDescription }
            planStatus = nil
        }
    }

    var planFeedbackContent: some View {
        podcastContent
            .confirmationDialog("Delete this planned podcast?", isPresented: Binding(get: { deletingPlan != nil }, set: { if !$0 { deletingPlan = nil } }),
                                titleVisibility: .visible, presenting: deletingPlan) { plan in
                Button("Delete Plan", role: .destructive) { deletePlan(plan) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its script, storyboard and frames are removed. Points already spent on planning aren't refunded.")
            }
            .alert("Couldn't Open Plan", isPresented: Binding(get: { planError != nil }, set: { if !$0 { planError = nil } })) {
                Button("OK", role: .cancel) { planError = nil }
            } message: { Text(planError ?? "") }
            .overlay {
                if let planStatus {
                    ProgressView(planStatus).padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sensoryFeedback(.success, trigger: planChanges)
            .sensoryFeedback(.error, trigger: planError)
    }

    var documentCreationContent: some View {
        planFeedbackContent
            .sheet(isPresented: $showsNewGraph) {
                NewGraphSheet(api: environment.api, onCreated: openCreated)
            }
            .sheet(isPresented: $showsNewTodo) {
                TodoEditorSheet(api: environment.api) { created in
                    Task {
                        if let summary = try? await environment.api.summary(id: created.id) {
                            environment.library.insert(summary)
                            try? await Task.sleep(for: .milliseconds(350))
                            stackPath.wrappedValue.append(summary)
                        } else { await environment.library.reload() }
                    }
                }
            }
            .sheet(isPresented: $showsViewedResumes, onDismiss: {
                if let slug = selectedPublicationSlug { selectedPublicationSlug = nil; environment.pendingRoute = .slug(slug) }
            }) {
                ViewedResumeLinksSheet(api: environment.api) { slug in selectedPublicationSlug = slug; showsViewedResumes = false }
            }
            .sheet(isPresented: $showsNewResume) {
                NewResumeSheet(api: environment.api) { openCreated(id: $0.familyId) }
            }
            .sheet(isPresented: $showsNewDocument) {
                NewRichDocumentSheet(api: environment.api, onCreated: openCreated)
            }
            .sheet(isPresented: $showsNewPaper) {
                NewPaperSheet(api: environment.api, onCreated: openCreated)
            }
            .sheet(isPresented: $showsCredits) {
                SummaryCreditsSheet(environment: environment)
            }
    }

    var newDocumentMenu: some View {
        Menu {
            Section {
                Button {
                    showsNewSummary = true
                } label: {
                    Label("Summary", systemImage: "text.quote")
                }
                .accessibilityIdentifier("new-summary-menu-summary")
                Button {
                    showsNewPaper = true
                } label: {
                    Label("Paper", systemImage: "doc.richtext")
                }
                .accessibilityIdentifier("new-paper")
                Button {
                    showsNewGraph = true
                } label: {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .accessibilityIdentifier("new-graph")
                Button {
                    showsNewDocument = true
                } label: {
                    Label("Document", systemImage: "doc.text.image")
                }
                .accessibilityIdentifier("new-rich-document")
                Button("Résumé", systemImage: "person.text.rectangle") { showsNewResume = true }
                    .accessibilityIdentifier("new-resume")
                Button { showsNewTodo = true } label: { Label("Todo List", systemImage: "checklist") }
                    .accessibilityIdentifier("new-todo-list")
            }
            Section {
                Button {
                    showsNewTrip = true
                } label: {
                    Label("Trip", systemImage: "map")
                }
                .accessibilityIdentifier("new-trip")
            }
            Section {
                Button { environment.libraryCreation = .podcast() } label: {
                    Label("Podcast", systemImage: "waveform")
                }
                .accessibilityIdentifier("new-podcast")
                Button { environment.libraryCreation = .audiobook } label: {
                    Label("Audiobook", systemImage: "book")
                }
                .accessibilityIdentifier("new-audiobook")
                Button { showsNewMiniApp = true } label: {
                    Label("Clip", systemImage: "app.badge")
                }
                .accessibilityIdentifier("new-mini-app")
            }
        } label: {
            Label("New", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .accessibilityIdentifier("new-summary")
        .sensoryFeedback(.selection, trigger: showsNewSummary) { _, presented in presented }
        .sensoryFeedback(.selection, trigger: showsNewPaper) { _, presented in presented }
        .sensoryFeedback(.selection, trigger: showsNewGraph) { _, presented in presented }
        .sensoryFeedback(.selection, trigger: showsNewResume)
        .sensoryFeedback(.selection, trigger: showsNewTodo) { _, presented in presented }
        .sensoryFeedback(.selection, trigger: showsNewDocument) { _, presented in presented }
        .sensoryFeedback(.selection, trigger: showsNewTrip) { _, presented in presented }
        .sensoryFeedback(.selection, trigger: showsNewMiniApp) { _, presented in presented }
    }

    func refreshPlans() {
        Task { await model.refreshPlannedPodcasts() }
    }

    func openPlan(_ summary: PodcastPlanSummary) {
        podcastTaps += 1
        planStatus = String(localized: "Opening plan…")
        Task {
            do {
                let plan = try await environment.api.podcastPlan(id: summary.id)
                planStatus = nil
                if plan.confirmed {
                    model.removePlannedPodcast(id: plan.id)
                    guard let day = summary.day else { refreshPlans(); return }
                    planStatus = String(localized: "Loading podcast…")
                    let podcast = try await environment.api.savedPodcast(key: plan.id, day: day)
                    planStatus = nil
                    environment.podcastPlayer.present(podcast: podcast)
                } else {
                    environment.libraryCreation = .resumedPodcast(plan, library: summary.library)
                }
            } catch {
                planStatus = nil
                planError = error.localizedDescription
                refreshPlans()
            }
        }
    }

    func deletePlan(_ plan: PodcastPlanSummary) {
        planStatus = String(localized: "Deleting plan…")
        Task {
            do {
                try await environment.api.deletePodcastPlan(id: plan.id)
                withAnimation { model.removePlannedPodcast(id: plan.id) }
                planChanges += 1
            } catch { planError = error.localizedDescription }
            planStatus = nil
        }
    }

    /// Pushes a paper made in the New Paper sheet once the sheet has closed.
    func openCreated(_ paper: Paper) {
        Task {
            guard let summary = await environment.libraryItem(forCreated: paper) else { return }
            // Let the sheet finish dismissing before pushing.
            try? await Task.sleep(for: .milliseconds(350))
            stackPath.wrappedValue.append(summary)
        }
    }

    /// Pushes a graph made in the New Graph sheet once the sheet has closed.
    func openCreated(_ graph: Graph) { openCreated(id: graph.id) }

    /// Pushes a document made in the New Document sheet once the sheet has closed.
    func openCreated(_ document: RichDocument) { openCreated(id: document.id) }

    func openCreated(id: String) {
        Task {
            guard let summary = try? await environment.api.summary(id: id) else {
                await environment.library.reload()
                return
            }
            environment.library.insert(summary)
            try? await Task.sleep(for: .milliseconds(350))
            stackPath.wrappedValue.append(summary)
        }
    }
}

private extension LibraryView {
    var sharingContent: some View {
        documentCreationContent
            .xSharing($xSharingRequest, api: environment.api)
            .sheet(item: $sharingSummary) { summary in
                ShareModeSheet(summary: summary, api: environment.api) { updated in
                    environment.library.upsert(updated)
                    if isMiniApps { model.upsert(updated) }
                }
            }
            .sheet(item: $deletingSummary) { summary in
                DeleteSummarySheet(api: environment.api, summary: summary) {
                    model.remove(id: summary.id)
                    if isMiniApps { environment.library.remove(id: summary.id) }
                    environment.likes.remove(id: summary.id)
                    deletedCount += 1
                }
            }
            .sheet(item: $renamingSummary) { summary in
                RenameSummarySheet(api: environment.api, summary: summary) { updated in
                    environment.library.upsert(updated)
                    if isMiniApps { model.upsert(updated) }
                    renamedCount += 1
                    showsRenamedStatus = true
                }
            }
            .overlay(alignment: .bottom) {
                if showsRenamedStatus {
                    Label("Renamed", systemImage: "checkmark.circle")
                        .padding()
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .accessibilityIdentifier("chip-rename-success")
                }
            }
            .task(id: renamedCount) {
                guard showsRenamedStatus else { return }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                showsRenamedStatus = false
            }
            .sensoryFeedback(.success, trigger: renamedCount)
            .sensoryFeedback(.success, trigger: deletedCount)
            .sensoryFeedback(.selection, trigger: model.filter)
            .likeStatusOverlay($likeStatus)
    }

    @ToolbarContentBuilder
    var libraryToolbar: some ToolbarContent {
        if !isPhone {
            ToolbarItem(placement: .summaryLeading) {
                Button { showsCredits = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("\(pointsTitle) pts")
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .accessibilityLabel("Points: \(pointsTitle)")
                .accessibilityIdentifier("library-points")
            }
        }
        ToolbarItemGroup(placement: .summaryTrailing) {
            createButton
            Menu {
                if let openSearch {
                    Button {
                        podcastTaps += 1
                        openSearch()
                    } label: { Label("Search", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier("summary-search")
                }
                LibraryFilterMenu(model: model, showViewedResumes: { showsViewedResumes = true }, showMoreFilters: {
                    podcastTaps += 1
                    showsFilters = true
                }, applyFilter: applyFilter)
                backgroundJobsButton
            } label: {
                VStack(spacing: 3) {
                    ForEach(0..<3) { _ in
                        Circle().frame(width: 3, height: 3)
                    }
                }
                .frame(width: 22, height: 22)
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("Library Actions")
            .accessibilityIdentifier("library-actions")
        }
        ChatPanelToolbarContent(isVisible: chatPanelVisibility)
    }

    var backgroundJobsButton: some View {
        Button {
            podcastTaps += 1
            environment.backgroundJobsRequest = BackgroundJobsRequest()
        } label: { Label("Background Jobs", systemImage: "clock.arrow.circlepath") }
        .accessibilityIdentifier("background-jobs-toolbar")
    }

    @ViewBuilder
    var createButton: some View {
        if isMiniApps {
            Button { podcastTaps += 1; showsNewMiniApp = true } label: {
                Label("New Clip", systemImage: "plus")
            }
            .accessibilityIdentifier("new-mini-app")
        } else {
            newDocumentMenu
        }
    }
}
