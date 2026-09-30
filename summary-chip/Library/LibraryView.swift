import SummaryKit
import SwiftUI

struct LibraryView: View {
    @Bindable var environment: AppEnvironment
    @State private var showsFilters = false
    @State private var showsNewSummary = false
    @State private var sharingSummary: Summary?
    @State private var deletingSummary: Summary?
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    private var model: LibraryModel { environment.library }

    var body: some View {
        NavigationStack {
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
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsFilters = true
                        } label: {
                            Label("Filter", systemImage: model.filter.isActive
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                        }
                        .badge(model.filter.activeCount)
                        .accessibilityIdentifier("library-filter")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsNewSummary = true
                        } label: {
                            Label("New Summary", systemImage: "plus")
                        }
                        .accessibilityIdentifier("new-summary")
                    }
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
                .sheet(item: $sharingSummary) { summary in
                    ShareModeSheet(summary: summary)
                }
                .confirmationDialog(
                    "Delete this summary?",
                    isPresented: Binding(get: { deletingSummary != nil }, set: { if !$0 { deletingSummary = nil } }),
                    titleVisibility: .visible,
                    presenting: deletingSummary
                ) { summary in
                    Button("Delete Summary", role: .destructive) { Task { await delete(summary) } }
                } message: { _ in
                    Text("The link and preview stop working and the summary is removed permanently. To only stop sharing, make it private instead.")
                }
                .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
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
            SummaryCardFeed(entries: model.entries, onReachEnd: {
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
            .background(Color(.systemGroupedBackground))
        }
    }

    private func delete(_ summary: Summary) async {
        do {
            try await environment.api.deleteSummary(id: summary.id)
            withAnimation { model.remove(id: summary.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isOffline {
            ContentUnavailableView {
                Label("You're offline", systemImage: "wifi.slash")
            } description: {
                Text(!model.filter.isActive
                    ? "Summaries you open while online are saved on this device for offline reading."
                    : "No saved summaries match. Connect to the internet to search your whole library.")
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
                Text("Summaries you create, and ones you open from shared links, appear here. Share a web page, PDF or text to Summary Chip, or paste a link.")
            } actions: {
                Button("New Summary") { showsNewSummary = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
