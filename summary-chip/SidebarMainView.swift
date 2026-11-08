import SummaryKit
import SwiftUI

/// Large-screen layout (macOS, regular-width iPad and iPhone): navigation sidebar, the selected
/// page, and the agent chat as a collapsible trailing column.
struct SidebarMainView: View {
    let environment: AppEnvironment
    @Bindable var navigation: MainNavigationState
    /// What the split view shows. Mirrors `navigation.columnVisibility`, which only the user changes:
    /// while the layout settles (it was just created by unfolding, or the size class changed) the
    /// split view picks its own visibility, and that must not overwrite the user's choice.
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var layoutSettled = false
    @State private var settleTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(macOS)
    /// Remembered across launches so the chat panel reopens the way the user left it.
    @AppStorage("chatPanelVisible") private var showsChat = true
    #endif
    @State private var showsNewSummary = false
    @State private var showsNewTrip = false
    @State private var showsNewPaper = false
    @State private var showsNewGraph = false
    @State private var showsNewMiniApp = false
    @Environment(\.openPodcast) private var openPodcast
    @Environment(\.openMiniApp) private var openMiniApp

    init(environment: AppEnvironment, navigation: MainNavigationState) {
        self.environment = environment
        self.navigation = navigation
        _columnVisibility = State(initialValue: navigation.columnVisibility)
    }

    #if !os(macOS)
    private var showsChat: Bool {
        get { navigation.showsChat }
        nonmutating set { navigation.showsChat = newValue }
    }

    private var chatVisibility: Binding<Bool> { $navigation.showsChat }
    #else
    private var chatVisibility: Binding<Bool> { $showsChat }
    #endif

    private var sidebarSelection: Binding<MainTab?> {
        Binding(get: { navigation.selection }, set: { if let tab = $0 { navigation.selection = tab } })
    }

    var body: some View {
        // The chat column sits beside the split view, not in it: `.inspector` collapses the sidebar
        // when it needs room, and a pushed page covers anything placed inside the detail column.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                navigationView
                    .simultaneousGesture(TapGesture().onEnded { navigation.lastFocusedChat = false })
                if showsChat && navigation.selection != .chat {
                    Divider()
                        .ignoresSafeArea()
                    agentPanel
                        .simultaneousGesture(TapGesture().onEnded { navigation.lastFocusedChat = true })
                        .frame(width: Self.panelWidth(inWindowWidth: geometry.size.width))
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .environment(\.chatPanelVisibility, chatVisibility)
        .environment(\.openSideAgent, { model in
            navigation.sideAgent = model
            navigation.lastFocusedChat = true
            showsChat = true
        })
        .environment(\.setSideAgentContext, { model in
            let id = model.summaryID ?? model.trip?.id ?? model.graph?.id ?? model.miniAppID
            guard id == activeDocument?.id else { return }
            navigation.sideAgent = model
        })
        .onChange(of: navigation.selection) { _, selection in
            if selection != .chat { navigation.contentSelection = selection }
            updateDocumentContext()
        }
        .onAppear {
            // Expanding while the compact Chat tab is selected moves chat into its side panel.
            if navigation.selection == .chat {
                navigation.selection = navigation.contentSelection
                navigation.lastFocusedChat = true
                showsChat = true
            }
            updateDocumentContext()
            settleLayout()
        }
        .onDisappear { settleTask?.cancel() }
        .onChange(of: horizontalSizeClass) { _, _ in settleLayout() }
        .onChange(of: columnVisibility) { _, visibility in
            if layoutSettled { navigation.columnVisibility = visibility }
        }
        .onChange(of: navigation.columnVisibility) { _, visibility in
            if columnVisibility != visibility { columnVisibility = visibility }
        }
        .onChange(of: navigation.libraryPath) { _, _ in updateDocumentContext() }
        .onChange(of: navigation.likesPath) { _, _ in updateDocumentContext() }
        .onChange(of: navigation.miniAppsPath) { _, _ in updateDocumentContext() }
        .summarySearchPresentation(environment: environment, onOpenSummary: openFromSearch)
        .environment(\.openLibraryItem, openFromSearch)
        .sheet(isPresented: $showsNewSummary) {
            NewSummarySheet(environment: environment)
        }
        .sheet(isPresented: $showsNewTrip) {
            NewTripSheet(api: environment.api) { trip in
                Task {
                    guard let summary = await environment.libraryItem(forCreated: trip) else { return }
                    navigation.selection = .library
                    navigation.libraryPath = [summary]
                }
            }
        }
        .sheet(isPresented: $showsNewPaper) {
            NewPaperSheet(api: environment.api) { paper in
                Task {
                    guard let summary = await environment.libraryItem(forCreated: paper) else { return }
                    navigation.selection = .library
                    navigation.libraryPath = [summary]
                }
            }
        }
        .sheet(isPresented: $showsNewGraph) {
            NewGraphSheet(api: environment.api) { graph in
                Task {
                    guard let summary = try? await environment.api.summary(id: graph.id) else { return }
                    environment.library.insert(summary)
                    navigation.selection = .library
                    navigation.libraryPath = [summary]
                }
            }
        }
        .sheet(isPresented: $showsNewMiniApp) {
            NewMiniAppSheet(environment: environment) { app in
                Task {
                    guard let summary = try? await environment.api.summary(id: app.id) else { return }
                    environment.library.upsert(summary)
                    navigation.selection = .miniApps
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
        .focusedSceneValue(\.chatPanelVisibility, chatVisibility)
    }

    private var navigationView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                Label("Feed", systemImage: "square.stack").tag(MainTab.library)
                #if os(macOS)
                Label("Discover", systemImage: "safari").tag(MainTab.discover)
                    .accessibilityIdentifier("sidebar-discover")
                #endif
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
                .modifier(DailyPodcastBottomInset(player: environment.podcastPlayer))
                .navigationSplitViewColumnWidth(min: 100, ideal: 500)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.selection {
        case .library: LibraryView(environment: environment, path: $navigation.libraryPath)
        case .miniApps: LibraryView(environment: environment, path: $navigation.miniAppsPath, kind: .miniApp)
        case .likes: LikesView(environment: environment, path: $navigation.likesPath)
        case .discover: MarketplaceScreen(environment: environment)
        case .settings: SettingsView(environment: environment)
        case .chat: ChatView(environment: environment)
        }
    }

    private var agentPanel: some View {
        ChatView(environment: environment, isPanel: true, model: navigation.chatModel(environment: environment), onClose: {
            navigation.lastFocusedChat = false
            withAnimation { showsChat = false }
        }, onFocus: { navigation.lastFocusedChat = true })
            .id(ObjectIdentifier(navigation.chatModel(environment: environment)))
            .environment(\.openLibraryItem, openFromSearch)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-panel")
    }

    /// A share of the window on narrow layouts, within the range a chat stays readable at.
    private static func panelWidth(inWindowWidth width: CGFloat) -> CGFloat {
        min(380, max(320, width * 0.4))
    }

    /// Ignores the split view's own visibility changes for a moment after the layout appears or
    /// changes size class, then puts back the sidebar the way the user left it.
    private func settleLayout() {
        layoutSettled = false
        columnVisibility = navigation.columnVisibility
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            columnVisibility = navigation.columnVisibility
            layoutSettled = true
        }
    }

    private var activeDocument: Summary? {
        switch navigation.selection {
        case .library: navigation.libraryPath.last
        case .likes: navigation.likesPath.last
        case .miniApps: navigation.miniAppsPath.last
        case .settings, .discover, .chat: nil
        }
    }

    private func updateDocumentContext() {
        guard let document = activeDocument, !document.isExpired else {
            navigation.sideAgent = nil
            return
        }
        let currentID = navigation.sideAgent.flatMap { $0.summaryID ?? $0.trip?.id ?? $0.graph?.id ?? $0.miniAppID }
        guard currentID != document.id else { return }
        let usesSpecialist = document.isOwner
        navigation.sideAgent = ChatModel(
            client: environment.chatClient, store: environment.chatStore,
            summaryID: usesSpecialist && document.kind == .miniApp ? nil : document.id,
            trip: usesSpecialist && document.kind == .trip ? TripChat(id: document.id, title: document.title) : nil,
            miniAppID: usesSpecialist && document.kind == .miniApp ? document.id : nil,
            graph: usesSpecialist && document.kind == .graph ? GraphChat(id: document.id) : nil
        )
    }

    /// Opens a search result in its document's tab.
    private func openFromSearch(_ summary: Summary) {
        if (summary.kind == .podcast || summary.kind == .audiobook), !summary.isExpired, let openPodcast {
            openPodcast(summary)
            return
        }
        if summary.kind == .miniApp {
            navigation.selection = .miniApps
            openClip(summary)
        } else {
            navigation.selection = .library
            navigation.libraryPath = [summary]
        }
    }

    private func openClip(_ summary: Summary) {
        if let openMiniApp { openMiniApp(summary) } else { navigation.miniAppsPath = [summary] }
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
#if !os(visionOS)
            ToolbarSpacer(.fixed, placement: placement)
#endif
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
