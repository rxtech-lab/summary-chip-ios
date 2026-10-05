import SummaryKit
import SwiftUI

/// Large-screen layout (macOS, regular-width iPad): navigation sidebar, the selected page,
/// and the library-wide chat as a collapsible trailing column.
struct SidebarMainView: View {
    let environment: AppEnvironment
    @State private var selection: MainTab? = .library
    #if os(macOS)
    /// Remembered across launches so the chat panel reopens the way the user left it.
    @AppStorage("chatPanelVisible") private var showsChat = true
    #else
    @State private var showsChat = true
    #endif
    @State private var showsNewSummary = false
    @State private var showsNewTrip = false
    @State private var libraryPath: [Summary] = []
    @State private var likesPath: [Summary] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Library", systemImage: "square.stack").tag(MainTab.library)
                Label("Likes", systemImage: "star")
                    .tag(MainTab.likes)
                    .accessibilityIdentifier("sidebar-likes")
                Label("Settings", systemImage: "gearshape")
                    .tag(MainTab.settings)
                    .accessibilityIdentifier("mac-settings")
            }
            .listStyle(.sidebar)
            .navigationTitle("Chippy")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .accessibilityIdentifier("mac-sidebar")
        } detail: {
            Group {
                switch selection ?? .library {
                case .library, .chat: LibraryView(environment: environment, path: $libraryPath)
                case .likes: LikesView(environment: environment, path: $likesPath)
                case .settings: SettingsView(environment: environment)
                }
            }
            .environment(\.chatPanelVisibility, $showsChat)
            .inspector(isPresented: $showsChat) {
                ChatView(environment: environment, isPanel: true)
                    .environment(\.openLibraryItem, openFromSearch)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
            }
        }
        .summarySearchPresentation(environment: environment, onOpenSummary: openFromSearch)
        .environment(\.openLibraryItem, openFromSearch)
        .sheet(isPresented: $showsNewSummary) {
            NewSummarySheet(environment: environment)
        }
        .sheet(isPresented: $showsNewTrip) {
            NewTripSheet(api: environment.api) { trip in
                Task {
                    guard let summary = await environment.libraryItem(forCreated: trip) else { return }
                    selection = .library
                    libraryPath = [summary]
                }
            }
        }
        .focusedSceneValue(\.newSummaryAction, { showsNewSummary = true })
        .focusedSceneValue(\.newTripAction, { showsNewTrip = true })
        .focusedSceneValue(\.chatPanelVisibility, $showsChat)
    }

    /// A search result opens as the Library's detail page.
    private func openFromSearch(_ summary: Summary) {
        selection = .library
        libraryPath = [summary]
    }
}

extension EnvironmentValues {
    /// Opens an item in the main Library navigation after a preview sheet closes.
    @Entry var openLibraryItem: ((Summary) -> Void)?
    /// Set by `SidebarMainView`; pages add a toolbar toggle for the chat column when present.
    @Entry var chatPanelVisibility: Binding<Bool>?
}

/// Toolbar group for the trailing chat column, kept apart from the page's own actions.
/// The chat panel's "New Chat" item lands right after it, so chat actions share one group.
/// Used inside a page's own `NavigationStack` so it lands in that page's bar on iPad.
struct ChatPanelToolbarContent: ToolbarContent {
    let isVisible: Binding<Bool>?

    var body: some ToolbarContent {
        if let isVisible {
            ToolbarSpacer(.fixed, placement: .summaryTrailing)
            ToolbarItem(placement: .summaryTrailing) {
                Button {
                    withAnimation { isVisible.wrappedValue.toggle() }
                } label: {
                    Label(isVisible.wrappedValue ? String(localized: "Hide Chat") : String(localized: "Show Chat"),
                          systemImage: "sparkles")
                }
                .accessibilityIdentifier("toggle-chat-panel")
            }
        }
    }
}

private struct NewSummaryActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct NewTripActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newSummaryAction: (() -> Void)? {
        get { self[NewSummaryActionKey.self] }
        set { self[NewSummaryActionKey.self] = newValue }
    }

    @Entry var chatPanelVisibility: Binding<Bool>?

    var newTripAction: (() -> Void)? {
        get { self[NewTripActionKey.self] }
        set { self[NewTripActionKey.self] = newValue }
    }
}

#if os(macOS)
struct SummaryMacCommands: Commands {
    @FocusedValue(\.newSummaryAction) private var newSummary
    @FocusedValue(\.chatPanelVisibility) private var chatPanel
    @FocusedValue(\.newTripAction) private var newTrip

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Summary", systemImage: "plus") { newSummary?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newSummary == nil)
            Button("New Trip", systemImage: "map") { newTrip?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(newTrip == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(chatPanel?.wrappedValue == true ? String(localized: "Hide Chat") : String(localized: "Show Chat")) {
                chatPanel?.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(chatPanel == nil)
        }
    }
}
#endif
