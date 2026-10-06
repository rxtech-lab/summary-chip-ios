import SummaryKit
import SwiftUI

/// Search results over the whole library, presented above the current screen. Picking a result
/// hands it to `onOpenSummary`, which closes search and shows the summary in the main navigation.
struct SearchView: View {
    @Bindable var environment: AppEnvironment
    @State private var model: SearchModel
    @State private var sharingSummary: Summary?
    @State private var deletingSummary: Summary?
    @FocusState private var inputFocused: Bool
    let onClose: () -> Void
    let onOpenSummary: (Summary) -> Void

    init(environment: AppEnvironment, onClose: @escaping () -> Void, onOpenSummary: @escaping (Summary) -> Void) {
        self.onClose = onClose
        self.onOpenSummary = onOpenSummary
        self.environment = environment
        _model = State(initialValue: SearchModel(api: environment.api, offline: environment.library.offline))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.isSearching {
                        searchingOverlay
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: model.isSearching)
        }
        .background(Color.summaryGroupedBackground)
        .sheet(item: $sharingSummary) { summary in
            ShareModeSheet(summary: summary, api: environment.api) { environment.library.upsert($0) }
        }
        .sheet(item: $deletingSummary) { summary in
            DeleteSummarySheet(api: environment.api, summary: summary) {
                withAnimation {
                    model.remove(id: summary.id)
                    environment.library.remove(id: summary.id)
                }
            }
        }
        .onAppear { inputFocused = true }
        #if os(macOS)
        .onExitCommand(perform: onClose)
        #endif
        .task(id: model.searchText) { await model.search() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                searchField
                closeButton
            }
            if let resultsCaption {
                Text(resultsCaption)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
                    .accessibilityIdentifier("search-results-count")
            }
        }
        .padding(.horizontal, 16)
        #if os(iOS)
        .padding(.top, 24)
        #else
        .padding(.top, 16)
        #endif
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.18), value: resultsCaption)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Titles, summaries or tags", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .autocorrectionDisabled(true)
                .summaryInputCapitalization()
                .submitLabel(.search)
                .accessibilityIdentifier("search-input")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    inputFocused = true
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("clear-search")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.easeInOut(duration: 0.15), value: model.searchText.isEmpty)
    }

    @ViewBuilder
    private var closeButton: some View {
        #if os(iOS)
        Button("Cancel", action: onClose)
            .fontWeight(.medium)
            .accessibilityIdentifier("close-search")
        #else
        Button(action: onClose) {
            Label("Close Search", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("close-search")
        .help("Close Search")
        #endif
    }

    /// "12 results" above the feed once a search has answered with something.
    private var resultsCaption: String? {
        guard !model.loadedQuery.isEmpty, !model.items.isEmpty else { return nil }
        let count = model.items.count
        if model.nextCursor != nil { return String(localized: "\(count)+ results") }
        return count == 1 ? String(localized: "1 result") : String(localized: "\(count) results")
    }

    @ViewBuilder
    private var content: some View {
        if model.query.isEmpty {
            ContentUnavailableView(
                "Search Summaries",
                systemImage: "text.magnifyingglass",
                description: Text("Find any summary in your library by its title, text or tag.")
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
            }, onSelect: { summary in
                inputFocused = false
                onOpenSummary(summary)
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
            .scrollDismissesKeyboard(.immediately)
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
    let onOpenSummary: (Summary) -> Void
    @State private var showsSearch = false
    #if os(iOS)
    /// Opened once the sheet has finished dismissing, so the push isn't lost mid-transition.
    @State private var pendingSummary: Summary?
    #endif

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
                            SearchView(
                                environment: environment,
                                onClose: { showsSearch = false },
                                onOpenSummary: { summary in
                                    showsSearch = false
                                    onOpenSummary(summary)
                                }
                            )
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
            .sheet(isPresented: $showsSearch, onDismiss: {
                guard let summary = pendingSummary else { return }
                pendingSummary = nil
                onOpenSummary(summary)
            }) {
                SearchView(environment: environment, onClose: { showsSearch = false }, onOpenSummary: { summary in
                    pendingSummary = summary
                    showsSearch = false
                })
                .presentationDragIndicator(.visible)
            }
            #endif
    }
}

extension View {
    func summarySearchToolbar(isEnabled: Bool = true) -> some View {
        modifier(SummarySearchToolbar(isEnabled: isEnabled))
    }

    /// `onOpenSummary` shows a picked result in the main navigation after search closes.
    func summarySearchPresentation(
        environment: AppEnvironment,
        onOpenSummary: @escaping (Summary) -> Void
    ) -> some View {
        modifier(SummarySearchPresentation(environment: environment, onOpenSummary: onOpenSummary))
    }
}
