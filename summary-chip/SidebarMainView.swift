import SummaryKit
import SwiftUI

/// Large-screen layout (macOS, regular-width iPad and iPhone): navigation sidebar, the selected
/// page, and the agent chat as a collapsible trailing column.
struct SidebarMainView: View {
    let environment: AppEnvironment
    @State private var sideAgent: ChatModel?
    @State private var selection: MainTab? = .library
    /// Only the sidebar's own control changes this; the chat column never does.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #if os(macOS)
    /// Remembered across launches so the chat panel reopens the way the user left it.
    @AppStorage("chatPanelVisible") private var showsChat = true
    #else
    @State private var showsChat = true
    #endif
    @State private var showsNewSummary = false
    @State private var showsNewTrip = false
    @State private var showsNewPaper = false
    @State private var showsNewGraph = false
    @State private var showsNewMiniApp = false
    @State private var libraryPath: [Summary] = []
    @State private var miniAppsPath: [Summary] = []
    @State private var likesPath: [Summary] = []
    @Environment(\.openPodcast) private var openPodcast
    @Environment(\.openMiniApp) private var openMiniApp

    var body: some View {
        // The chat column sits beside the split view, not in it: `.inspector` collapses the sidebar
        // when it needs room, and a pushed page covers anything placed inside the detail column.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                navigation
                if showsChat {
                    Divider()
                        .ignoresSafeArea()
                    agentPanel
                        .frame(width: Self.panelWidth(inWindowWidth: geometry.size.width))
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .environment(\.chatPanelVisibility, $showsChat)
        .environment(\.openSideAgent, { model in
            sideAgent = model
            showsChat = true
        })
        .environment(\.setSideAgentContext, { model in
            let id = model.summaryID ?? model.trip?.id ?? model.graph?.id ?? model.miniAppID
            guard id == activeDocument?.id else { return }
            sideAgent = model
        })
        .onChange(of: selection) { _, _ in updateDocumentContext() }
        .onChange(of: libraryPath) { _, _ in updateDocumentContext() }
        .onChange(of: likesPath) { _, _ in updateDocumentContext() }
        .onChange(of: miniAppsPath) { _, _ in updateDocumentContext() }
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
        .sheet(isPresented: $showsNewPaper) {
            NewPaperSheet(api: environment.api) { paper in
                Task {
                    guard let summary = await environment.libraryItem(forCreated: paper) else { return }
                    selection = .library
                    libraryPath = [summary]
                }
            }
        }
        .sheet(isPresented: $showsNewGraph) {
            NewGraphSheet(api: environment.api) { graph in
                Task {
                    guard let summary = try? await environment.api.summary(id: graph.id) else { return }
                    environment.library.insert(summary)
                    selection = .library
                    libraryPath = [summary]
                }
            }
        }
        .sheet(isPresented: $showsNewMiniApp) {
            NewMiniAppSheet(environment: environment) { app in
                Task {
                    guard let summary = try? await environment.api.summary(id: app.id) else { return }
                    environment.library.upsert(summary)
                    selection = .miniApps
                    openClip(summary)
                }
            }
        }
        // "Open in Feed" from a link sheet.
        .onChange(of: environment.pendingLibraryItem) { _, item in
            guard let item else { return }
            environment.pendingLibraryItem = nil
            openFromSearch(item)
        }
        .focusedSceneValue(\.newSummaryAction, { showsNewSummary = true })
        .focusedSceneValue(\.newTripAction, { showsNewTrip = true })
        .focusedSceneValue(\.newPaperAction, { showsNewPaper = true })
        .focusedSceneValue(\.newGraphAction, { showsNewGraph = true })
        .focusedSceneValue(\.newMiniAppAction, { showsNewMiniApp = true })
        .focusedSceneValue(\.chatPanelVisibility, $showsChat)
    }

    private var navigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Label("Feed", systemImage: "square.stack").tag(MainTab.library)
                Label("Clips", systemImage: "app.badge")
                    .tag(MainTab.miniApps)
                    .accessibilityIdentifier("sidebar-mini-apps")
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
            page
                .navigationSplitViewColumnWidth(min: 100, ideal: 500)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var page: some View {
        switch selection ?? .library {
        case .library, .chat: LibraryView(environment: environment, path: $libraryPath)
        case .miniApps: LibraryView(environment: environment, path: $miniAppsPath, kind: .miniApp)
        case .likes: LikesView(environment: environment, path: $likesPath)
        case .settings: SettingsView(environment: environment)
        }
    }

    private var agentPanel: some View {
        ChatView(environment: environment, isPanel: true, model: sideAgent, onClose: { withAnimation { showsChat = false } })
            .id(sideAgent.map { ObjectIdentifier($0) })
            .environment(\.openLibraryItem, openFromSearch)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-panel")
    }

    /// A share of the window on narrow layouts, within the range a chat stays readable at.
    private static func panelWidth(inWindowWidth width: CGFloat) -> CGFloat {
        min(380, max(320, width * 0.4))
    }

    private var activeDocument: Summary? {
        switch selection ?? .library {
        case .library, .chat: libraryPath.last
        case .likes: likesPath.last
        case .miniApps: miniAppsPath.last
        case .settings: nil
        }
    }

    private func updateDocumentContext() {
        guard let document = activeDocument, !document.isExpired else {
            sideAgent = nil
            return
        }
        let currentID = sideAgent.flatMap { $0.summaryID ?? $0.trip?.id ?? $0.graph?.id ?? $0.miniAppID }
        guard currentID != document.id else { return }
        let usesSpecialist = document.isOwner
        sideAgent = ChatModel(
            client: environment.chatClient, store: environment.chatStore,
            summaryID: usesSpecialist && document.kind == .miniApp ? nil : document.id,
            trip: usesSpecialist && document.kind == .trip ? TripChat(id: document.id, title: document.title) : nil,
            miniAppID: usesSpecialist && document.kind == .miniApp ? document.id : nil,
            graph: usesSpecialist && document.kind == .graph ? GraphChat(id: document.id) : nil
        )
    }

    /// Opens a search result in its document's tab.
    private func openFromSearch(_ summary: Summary) {
        if summary.kind == .podcast, !summary.isExpired, let openPodcast {
            openPodcast(summary)
            return
        }
        if summary.kind == .miniApp {
            selection = .miniApps
            openClip(summary)
        } else {
            selection = .library
            libraryPath = [summary]
        }
    }

    private func openClip(_ summary: Summary) {
        if let openMiniApp { openMiniApp(summary) } else { miniAppsPath = [summary] }
    }
}

extension EnvironmentValues {
    @Entry var openSideAgent: ((ChatModel) -> Void)?
    /// Updates the visible document's agent without changing panel visibility.
    @Entry var setSideAgentContext: ((ChatModel) -> Void)?
    /// Opens an item in the main Library navigation after a preview sheet closes.
    @Entry var openLibraryItem: ((Summary) -> Void)?
    /// Set by `SidebarMainView`; pages add a toolbar toggle for the chat column when present.
    @Entry var chatPanelVisibility: Binding<Bool>?
}

/// Keeps the chat toggle in the page toolbar whether the trailing column is open or closed.
struct ChatPanelToolbarContent: ToolbarContent {
    let isVisible: Binding<Bool>?

    // Keep the panel toggle after page-specific primary actions, including pushed details.
    private var placement: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .primaryAction
        #endif
    }

    var body: some ToolbarContent {
        if let isVisible {
            ToolbarSpacer(.fixed, placement: placement)
            ToolbarItem(placement: placement) {
                Button {
                    withAnimation { isVisible.wrappedValue.toggle() }
                } label: {
                    Label(isVisible.wrappedValue ? String(localized: "Hide Chat") : String(localized: "Show Chat"), systemImage: "sparkles")
                }
                .accessibilityIdentifier("toggle-chat-panel")
                #if os(iOS)
                .sensoryFeedback(.selection, trigger: isVisible.wrappedValue)
                #endif
            }
        }
    }
}

extension View {
    /// Adds the chat column's toggle to a page pushed inside `SidebarMainView`.
    func chatPanelToolbar() -> some View { modifier(ChatPanelToolbarModifier()) }
}

private struct ChatPanelToolbarModifier: ViewModifier {
    @Environment(\.chatPanelVisibility) private var visibility

    func body(content: Content) -> some View {
        content.toolbar { ChatPanelToolbarContent(isVisible: visibility) }
    }
}

/// A document's own agent button, for layouts without the chat column. Where the column exists,
/// its toolbar toggle already opens the agent for the visible document.
struct AgentChatToggle: View {
    @Environment(\.chatPanelVisibility) private var visibility
    let open: () -> Void
    @State private var feedback = 0

    var body: some View {
        if visibility == nil {
            Button {
                feedback += 1
                open()
            } label: {
                Label("Show Chat", systemImage: "sparkles")
            }
            .sensoryFeedback(.selection, trigger: feedback)
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

    @Entry var newPaperAction: (() -> Void)?
    @Entry var newGraphAction: (() -> Void)?
    @Entry var newMiniAppAction: (() -> Void)?
}

#if os(macOS)
struct SummaryMacCommands: Commands {
    @FocusedValue(\.newSummaryAction) private var newSummary
    @FocusedValue(\.chatPanelVisibility) private var chatPanel
    @FocusedValue(\.newTripAction) private var newTrip
    @FocusedValue(\.newPaperAction) private var newPaper
    @FocusedValue(\.newGraphAction) private var newGraph
    @FocusedValue(\.newMiniAppAction) private var newMiniApp

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Summary", systemImage: "plus") { newSummary?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newSummary == nil)
            Button("New Trip", systemImage: "map") { newTrip?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(newTrip == nil)
            Button("New Paper", systemImage: "doc.richtext") { newPaper?() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(newPaper == nil)
            Button("New Graph", systemImage: "point.3.connected.trianglepath.dotted") { newGraph?() }
                .disabled(newGraph == nil)
            Button("New Clip", systemImage: "app.badge") { newMiniApp?() }
                .disabled(newMiniApp == nil)
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
