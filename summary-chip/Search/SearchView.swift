import SummaryKit
import SwiftUI

/// Search has its own navigation and results, preserving the screen underneath it.
struct SearchView: View {
    @Bindable var environment: AppEnvironment
    @State private var model: SearchModel
    @State private var sharingSummary: Summary?
    @State private var deletingSummary: Summary?
    @FocusState private var inputFocused: Bool
    let onClose: () -> Void

    init(environment: AppEnvironment, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.environment = environment
        _model = State(initialValue: SearchModel(api: environment.api, offline: environment.library.offline))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            NavigationStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.summaryGroupedBackground)
                    .overlay {
                        if model.isSearching {
                            searchingOverlay
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: model.isSearching)
                    .navigationTitle("Search")
                    .summaryInlineNavigationTitle()
                    .navigationDestination(for: Summary.self) { summary in
                        SummaryDetailView(environment: environment, summary: summary)
                            .onAppear { inputFocused = false }
                    }
                    .sheet(item: $sharingSummary) { summary in
                        ShareModeSheet(summary: summary)
                    }
                    .sheet(item: $deletingSummary) { summary in
                        DeleteSummarySheet(api: environment.api, summary: summary) {
                            withAnimation {
                                model.remove(id: summary.id)
                                environment.library.remove(id: summary.id)
                            }
                        }
                    }
            }
        }
        .background(Color.summaryGroupedBackground)
        .onAppear { inputFocused = true }
        #if os(macOS)
        .onExitCommand(perform: onClose)
        #endif
        .task(id: model.searchText) { await model.search() }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your summaries", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .autocorrectionDisabled(true)
                .summaryInputCapitalization()
                .accessibilityIdentifier("search-input")
            Button(action: onClose) {
                Label("Close Search", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("close-search")
            .help("Close Search")
        }
        .padding(16)
        .background(.bar)
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

}

private struct OpenSummarySearchKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var openSummarySearch: (() -> Void)? {
        get { self[OpenSummarySearchKey.self] }
        set { self[OpenSummarySearchKey.self] = newValue }
    }
}

struct SummarySearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Search", systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier("open-search")
        .help("Search summaries")
    }
}

private struct SummarySearchToolbar: ViewModifier {
    @Environment(\.openSummarySearch) private var openSearch
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.toolbar {
            if isEnabled, let openSearch {
                ToolbarItem(placement: .summaryTrailing) {
                    SummarySearchButton(action: openSearch)
                }
            }
        }
    }
}

private struct SummarySearchPresentation: ViewModifier {
    let environment: AppEnvironment
    @State private var showsSearch = false

    func body(content: Content) -> some View {
        content
            .environment(\.openSummarySearch, { showsSearch = true })
            #if os(macOS)
            .disabled(showsSearch)
            .accessibilityHidden(showsSearch)
            .overlay {
                if showsSearch {
                    GeometryReader { geometry in
                        ZStack {
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture { showsSearch = false }
                                .accessibilityLabel("Dismiss Search")
                            SearchView(environment: environment) { showsSearch = false }
                                .frame(
                                    width: min(720, max(0, geometry.size.width - 48)),
                                    height: min(560, max(0, geometry.size.height - 48))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 20)
                                        .strokeBorder(.quaternary, lineWidth: 0.5)
                                }
                                .shadow(color: .black.opacity(0.2), radius: 24, y: 6)
                                .transition(.scale(scale: 0.97).combined(with: .opacity))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: showsSearch)
            .background {
                Button("Search") { showsSearch = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .hidden()
            }
            #else
            .sheet(isPresented: $showsSearch) {
                SearchView(environment: environment) { showsSearch = false }
                    .presentationDragIndicator(.visible)
            }
            #endif
    }
}

extension View {
    func summarySearchToolbar(isEnabled: Bool = true) -> some View {
        modifier(SummarySearchToolbar(isEnabled: isEnabled))
    }

    func summarySearchPresentation(environment: AppEnvironment) -> some View {
        modifier(SummarySearchPresentation(environment: environment))
    }
}
