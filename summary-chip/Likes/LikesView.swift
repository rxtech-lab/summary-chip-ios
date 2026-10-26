import SummaryKit
import SwiftUI

/// Summaries the user starred, most recently starred first. Opening one shows its detail page.
struct LikesView: View {
    @Bindable var environment: AppEnvironment
    @State private var feedScroll = SummaryFeedScrollState()
    @State private var didLoadInitially = false
    @State private var sharingSummary: Summary?
    @State private var likeStatus: LikeStatus?
    @State private var localPath: [Summary] = []
    /// Lets a parent (the sidebar layout) own the navigation path.
    var path: Binding<[Summary]>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSummarySearch) private var openSearch
    @Environment(\.chatPanelVisibility) private var chatPanelVisibility
    @Environment(\.openPodcast) private var openPodcast
    @Environment(\.openMiniApp) private var openMiniApp

    private var model: LikesModel { environment.likes }

    var body: some View {
        NavigationStack(path: (path ?? $localPath).presentingMiniApps(with: openMiniApp)) {
            content
                .navigationTitle("Likes")
                .navigationDestination(for: Summary.self) { summary in
                    if summary.isExpired {
                        ExpiredSummaryView(environment: environment, summary: summary)
                    } else {
                        SummaryDestination(environment: environment, summary: summary)
                    }
                }
                .refreshable { await model.reload() }
                .onChange(of: scenePhase) { _, phase in
                    // Pick up stars made on other devices whenever the app is reopened.
                    guard phase == .active, model.hasLoaded else { return }
                    Task { await model.reload() }
                }
                .toolbar {
                    if let openSearch {
                        ToolbarItem(placement: .summaryTrailing) {
                            SummarySearchButton(action: openSearch)
                        }
                    }
                    ChatPanelToolbarContent(isVisible: chatPanelVisibility)
                }
                .sheet(item: $sharingSummary) { summary in
                    ShareModeSheet(summary: summary, api: environment.api) { updated in
                        environment.library.upsert(updated)
                        environment.likes.upsert(updated)
                    }
                }
                .likeStatusOverlay($likeStatus)
        }
        // Load with the navigation container, rather than reloading page one when detail is popped.
        .task {
            guard !didLoadInitially else { return }
            await model.reload()
            didLoadInitially = model.hasLoaded
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView("Loading your likes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            emptyState
        } else {
            SummaryCardFeed(entries: model.entries, scrollState: feedScroll, showsTimeline: true, showsDateHeaders: true, onReachEnd: {
                Task { await model.loadMore() }
            }, onSelect: { summary in
                if summary.kind == .podcast, !summary.isExpired, let openPodcast { openPodcast(summary) }
                else { (path ?? $localPath).presentingMiniApps(with: openMiniApp).wrappedValue.append(summary) }
            }, menuItems: { summary in
                LikeMenuButton(summary: summary) { toggleLike(summary) }
                if !summary.isExpired {
                    Button {
                        sharingSummary = summary
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }) {
                if model.isLoadingMore {
                    ProgressView().padding()
                } else if model.isOffline {
                    Label("You're offline. Showing likes saved on this device.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                } else if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).padding()
                }
            }
            .background(Color.summaryGroupedBackground)
            .accessibilityIdentifier("likes-feed")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isOffline {
            ContentUnavailableView {
                Label("You're offline", systemImage: "wifi.slash")
            } description: {
                Text("Connect to the internet to see the summaries you starred.")
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Couldn't load your likes", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        } else {
            ContentUnavailableView(
                "No Likes Yet",
                systemImage: "star",
                description: Text("Star a summary to keep it here.")
            )
            .accessibilityIdentifier("likes-empty")
        }
    }

    private func toggleLike(_ summary: Summary) {
        Task {
            let (_, status) = await environment.toggleLike(summary)
            likeStatus = status
        }
    }
}
