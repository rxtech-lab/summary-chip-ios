import SummaryKit
import SwiftUI

struct LibraryView: View {
    @Bindable var environment: AppEnvironment
    @State private var showsFilters = false
    @State private var showsNewSummary = false
    @State private var showsNewTrip = false
    @State private var showsNewPaper = false
    @State private var showsCredits = false
    @State private var sharingSummary: Summary?
    @State private var deletingSummary: Summary?
    @State private var deletedCount = 0
    @State private var likeStatus: LikeStatus?
    @State private var localPath: [Summary] = []
    /// Lets a parent (the macOS sidebar layout) push a summary, e.g. one picked in search.
    var path: Binding<[Summary]>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSummarySearch) private var openSearch
    @Environment(\.chatPanelVisibility) private var chatPanelVisibility

    private var model: LibraryModel { environment.library }

    private var pointsTitle: String {
        environment.credits.points.map { $0.formatted() } ?? "–"
    }

    var body: some View {
        NavigationStack(path: path ?? $localPath) {
            content
                .navigationTitle("Library")
                .navigationDestination(for: Summary.self) { summary in
                    SummaryDestination(environment: environment, summary: summary)
                }
                .task { await model.reload() }
                .refreshable { await model.reload() }
                .onChange(of: scenePhase) { _, phase in
                    // Pick up summaries made elsewhere (share extension, web) whenever the app is reopened.
                    guard phase == .active, model.hasLoaded else { return }
                    Task { await model.reload() }
                }
                .toolbar {
                    ToolbarItem(placement: .summaryLeading) {
                        Button {
                            showsCredits = true
                        } label: {
                            // Toolbars collapse `Label` to its icon, so lay out the count explicitly.
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
                    ToolbarItemGroup(placement: .summaryTrailing) {
                        filterMenu
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
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        .accessibilityIdentifier("new-summary")
                        if let openSearch {
                            SummarySearchButton(action: openSearch)
                        }
                    }
                    ChatPanelToolbarContent(isVisible: chatPanelVisibility)
                }
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
                            if let path { path.wrappedValue.append(summary) } else { localPath.append(summary) }
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
                    ShareModeSheet(summary: summary, api: environment.api) { environment.library.upsert($0) }
                }
                .sheet(item: $deletingSummary) { summary in
                    DeleteSummarySheet(api: environment.api, summary: summary) {
                        model.remove(id: summary.id)
                        environment.likes.remove(id: summary.id)
                        deletedCount += 1
                    }
                }
                .sensoryFeedback(.success, trigger: deletedCount)
                .sensoryFeedback(.selection, trigger: model.filter)
                .likeStatusOverlay($likeStatus)
        }
    }

    /// Pushes a paper made in the New Paper sheet once the sheet has closed.
    private func openCreated(_ paper: Paper) {
        Task {
            guard let summary = await environment.libraryItem(forCreated: paper) else { return }
            // Let the sheet finish dismissing before pushing.
            try? await Task.sleep(for: .milliseconds(350))
            if let path { path.wrappedValue.append(summary) } else { localPath.append(summary) }
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

            Picker("Kind", selection: filterBinding(\.kind)) {
                Text("All").tag(SummaryKind?.none)
                ForEach(SummaryKind.known) { kind in
                    Text(kind.title).tag(SummaryKind?.some(kind))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("library-filter-kind")

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

            Divider()

            Button {
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
        model.filter = filter
        Task { await model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView("Loading your summaries…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            emptyState
        } else {
            SummaryCardFeed(entries: model.entries, showsTimeline: true, showsDateHeaders: true, onReachEnd: {
                Task { await model.loadMore() }
            }, menuItems: { summary in
                LikeMenuButton(summary: summary) {
                    Task { likeStatus = await environment.toggleLike(summary).1 }
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
                Label("Couldn't load your library", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        } else if model.filter.isActive {
            ContentUnavailableView(
                "No Matching Summaries",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No summaries match the current filters.")
            )
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
