import SummaryKit
import SwiftUI

struct LibraryView: View {
    @Bindable var environment: AppEnvironment
    @State private var feedScroll = SummaryFeedScrollState()
    @State private var didLoadInitially = false
    @State private var podcastTaps = 0
    @State private var showsFilters = false
    @State private var showsNewSummary = false
    @State private var showsNewTrip = false
    @State private var showsNewPodcast = false
    @State private var showsNewPaper = false
    @State private var showsNewMiniApp = false
    @State private var showsCredits = false
    @State private var sharingSummary: Summary?
    @State private var deletingSummary: Summary?
    @State private var deletedCount = 0
    @State private var likeStatus: LikeStatus?
    @State private var localPath: [Summary] = []
    @State private var model: LibraryModel
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
        NavigationStack(path: stackPath) {
            content
                .navigationTitle(isMiniApps ? String(localized: "Clips") : String(localized: "Feed"))
                .navigationDestination(for: Summary.self) { summary in
                    SummaryDestination(environment: environment, summary: summary)
                }
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
                .toolbar { libraryToolbar }
                .sensoryFeedback(.selection, trigger: podcastTaps)
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
                .sheet(isPresented: $showsNewPodcast) {
                    DailyPodcastGenerationSheet(api: environment.api, date: Date(), existing: nil, library: true) { podcast in
                        Task {
                            if let id = podcast.summaryId, let chip = try? await environment.api.summary(id: id) {
                                environment.library.insert(chip)
                            }
                            try? await Task.sleep(for: .milliseconds(350))
                            environment.podcastPlayer.present(podcast: podcast)
                        }
                    }
                }
                .sheet(isPresented: $showsNewPaper) {
                    NewPaperSheet(api: environment.api, onCreated: openCreated)
                }
                .sheet(isPresented: $showsCredits) {
                    SummaryCreditsSheet(environment: environment)
                }
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
                .sensoryFeedback(.success, trigger: deletedCount)
                .sensoryFeedback(.selection, trigger: model.filter)
                .likeStatusOverlay($likeStatus)
        }
        // Load with the navigation container, rather than reloading page one when detail is popped.
        .task {
            guard !didLoadInitially else { return }
            await model.reload()
            didLoadInitially = model.hasLoaded
        }
    }

    private var newDocumentMenu: some View {
        Menu {
            Button {
                showsNewSummary = true
            } label: {
                Label("New Summary", systemImage: "text.quote")
            }
            .accessibilityIdentifier("new-summary-menu-summary")
            Button {
                showsNewTrip = true
            } label: {
                Label("New Trip", systemImage: "map")
            }
            .accessibilityIdentifier("new-trip")
            Button {
                showsNewPaper = true
            } label: {
                Label("New Paper", systemImage: "doc.richtext")
            }
            .accessibilityIdentifier("new-paper")
            Button { podcastTaps += 1; showsNewPodcast = true } label: {
                Label("New Podcast", systemImage: "waveform")
            }.accessibilityIdentifier("new-podcast")
            Button { showsNewMiniApp = true } label: { Label("New Clip", systemImage: "app.badge") }
                .accessibilityIdentifier("new-mini-app")
        } label: {
            Label("New", systemImage: "plus")
        }
        .accessibilityIdentifier("new-summary")
    }

    /// Pushes a paper made in the New Paper sheet once the sheet has closed.
    private func openCreated(_ paper: Paper) {
        Task {
            guard let summary = await environment.libraryItem(forCreated: paper) else { return }
            // Let the sheet finish dismissing before pushing.
            try? await Task.sleep(for: .milliseconds(350))
            stackPath.wrappedValue.append(summary)
        }
    }

    /// Quick filters apply as soon as they're picked; category and tag need the searchable sheet.
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: filterBinding(\.scope)) {
                ForEach(LibraryScope.filterCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.inline)

            if model.kind == nil {
                Picker("Kind", selection: filterBinding(\.kind)) {
                    Text("All").tag(SummaryKind?.none)
                    ForEach(model.availableKinds) { kind in
                        Text(kind.title).tag(SummaryKind?.some(kind))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("library-filter-kind")
            }

            if model.filter.scope != .viewed {
                Picker("Visibility", selection: filterBinding(\.visibility)) {
                    Text("All").tag(SummaryVisibility?.none)
                    ForEach(SummaryVisibility.allCases) { value in
                        Text(value.title).tag(SummaryVisibility?.some(value))
                    }
                }
                .pickerStyle(.menu)
            }

            Picker("Source", selection: filterBinding(\.source)) {
                Text("Any source").tag(SummaryOrigin?.none)
                ForEach(SummaryOrigin.known) { origin in
                    Label { Text(origin.title) } icon: { origin.image }.tag(SummaryOrigin?.some(origin))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("library-filter-source")

            if model.kind == nil || model.kind == .summary || model.kind == .podcast {
                Toggle("Editor’s Pick", isOn: filterBinding(\.editorsPick))
                    .accessibilityIdentifier("library-filter-editors-pick")
            }

            Divider()

            Button {
                podcastTaps += 1
                showsFilters = true
            } label: {
                Label("More Filters…", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("library-filter-more")

            if model.filter.isActive {
                Button(role: .destructive) {
                    applyFilter(LibraryFilter())
                } label: {
                    Label("Clear All Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Label("Filter", systemImage: model.filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .badge(model.filter.activeCount)
        .accessibilityIdentifier("library-filter")
    }

    private func filterBinding<Value>(_ keyPath: WritableKeyPath<LibraryFilter, Value>) -> Binding<Value> {
        Binding {
            model.filter[keyPath: keyPath]
        } set: { value in
            var filter = model.filter
            filter[keyPath: keyPath] = value
            // Viewed summaries are always public; a visibility filter would only hide them.
            if filter.scope == .viewed { filter.visibility = nil }
            applyFilter(filter)
        }
    }

    private func applyFilter(_ filter: LibraryFilter) {
        guard filter != model.filter else { return }
        feedScroll.reset()
        model.filter = filter
        Task { await model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView(isMiniApps ? String(localized: "Loading your clips…") : String(localized: "Loading your summaries…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            emptyState
        } else {
            // Clips are a plain grid; only the Feed is grouped by day with a timeline.
            SummaryCardFeed(entries: model.entries, scrollState: feedScroll, editorPickIDs: model.editorPickIDs, showsTimeline: !isMiniApps, showsDateHeaders: !isMiniApps, onReachEnd: {
                Task { await model.loadMore() }
            }, onSelect: { summary in
                if summary.kind == .podcast, let openPodcast { openPodcast(summary) }
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
                Button {
                    sharingSummary = summary
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if summary.isOwner {
                    Divider()
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
            .background(Color.summaryGroupedBackground)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isOffline {
            ContentUnavailableView {
                Label("You're offline", systemImage: "wifi.slash")
            } description: {
                !model.filter.isActive
                    ? Text("Summaries you open while online are saved on this device for offline reading.")
                    : Text("No saved summaries match. Connect to the internet to search your whole library.")
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label(isMiniApps ? String(localized: "Couldn't load your clips") : String(localized: "Couldn't load your Feed"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        } else if model.filter.isActive {
            ContentUnavailableView(
                isMiniApps ? String(localized: "No Matching Clips") : String(localized: "No Matching Summaries"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(isMiniApps ? String(localized: "No clips match the current filters.") : String(localized: "No summaries match the current filters."))
            )
        } else if isMiniApps {
            ContentUnavailableView {
                Label("No clips yet", systemImage: "app.badge")
            } description: {
                Text("Create a clip or ask Chat to build one. Your saved clips appear here.")
            } actions: {
                Button("New Clip") { showsNewMiniApp = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("create-first-mini-app")
            }
        } else {
            ContentUnavailableView {
                Label("No summaries yet", systemImage: "text.quote")
            } description: {
                Text("Summaries you create, and ones you open from shared links, appear here. Share a web page, PDF or text to Chippy, or paste a link.")
            } actions: {
                Button("New Summary") { showsNewSummary = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private extension LibraryView {
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
                filterMenu
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
