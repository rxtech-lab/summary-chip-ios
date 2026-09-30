import SummaryKit
import SwiftUI

/// The dedicated Search tab (`Tab(role: .search)`): its own navigation stack and results, so the
/// Library feed stays untouched while searching.
struct SearchView: View {
    @Bindable var environment: AppEnvironment
    @State private var model: SearchModel
    @State private var sharingSummary: Summary?
    @State private var deletingSummary: Summary?
    @State private var errorMessage: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: SearchModel(api: environment.api, offline: environment.library.offline))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .overlay {
                    if model.isSearching {
                        searchingOverlay
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: model.isSearching)
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Summary.self) { summary in
                    SummaryDetailView(environment: environment, summary: summary)
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
        .searchable(text: $model.searchText, prompt: "Search your summaries")
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .task(id: model.searchText) { await model.search() }
    }

    @ViewBuilder
    private var content: some View {
        if model.query.isEmpty {
            ContentUnavailableView(
                "Search Summaries",
                systemImage: "magnifyingglass",
                description: Text("Find summaries by title, text or tag.")
            )
        } else if model.loadedQuery.isEmpty {
            // Query typed, debounce/fetch in flight — the overlay covers this.
            Color.clear
        } else if model.items.isEmpty {
            if model.isOffline {
                ContentUnavailableView(
                    "You're offline",
                    systemImage: "wifi.slash",
                    description: Text("No saved summaries match. Connect to the internet to search your whole library.")
                )
            } else {
                ContentUnavailableView.search(text: model.loadedQuery)
            }
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
                }
            }
        }
    }

    private var searchingOverlay: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Searching…")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func delete(_ summary: Summary) async {
        do {
            try await environment.api.deleteSummary(id: summary.id)
            withAnimation {
                model.remove(id: summary.id)
                environment.library.remove(id: summary.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
