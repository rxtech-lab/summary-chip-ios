import SummaryKit
import SwiftUI

struct LibraryView: View {
    @Bindable var environment: AppEnvironment
    @State private var showsFilters = false
    @State private var showsNewSummary = false
    @State private var showsCredits = false
    @State private var sharingSummary: Summary?
    @State private var deletingSummary: Summary?
    @State private var deletedCount = 0
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
                    SummaryDetailView(environment: environment, summary: summary)
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
                        Button {
                            showsFilters = true
                        } label: {
                            Label("Filter", systemImage: model.filter.isActive
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                        }
                        .badge(model.filter.activeCount)
                        .accessibilityIdentifier("library-filter")
                        Button {
                            showsNewSummary = true
                        } label: {
                            Label("New Summary", systemImage: "plus")
                        }
                        .accessibilityIdentifier("new-summary")
                        if let openSearch {
                            SummarySearchButton(action: openSearch)
                        }
                    }
                    ChatPanelToolbarContent(isVisible: chatPanelVisibility)
                }
                .sheet(isPresented: $showsFilters) {
                    LibraryFilterSheet(model: model) { newFilter in
                        model.filter = newFilter
                        Task { await model.reload() }
                    }
                }
                .sheet(isPresented: $showsNewSummary) {
                    NewSummarySheet(environment: environment)
                }
                .sheet(isPresented: $showsCredits) {
                    SummaryCreditsSheet(environment: environment)
                }
                .sheet(item: $sharingSummary) { summary in
                    ShareModeSheet(summary: summary)
                }
                .sheet(item: $deletingSummary) { summary in
                    DeleteSummarySheet(api: environment.api, summary: summary) {
                        withAnimation { model.remove(id: summary.id) }
                        deletedCount += 1
                    }
                }
                .sensoryFeedback(.success, trigger: deletedCount)
        }
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
