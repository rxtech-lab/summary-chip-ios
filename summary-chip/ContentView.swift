import RxAuthSwift
import RxAuthSwiftUI
import SummaryKit
import SwiftUI

struct ContentView: View {
    @Bindable var environment: AppEnvironment
    @State var navigation = MainNavigationState()
    @State private var onboarding = SummaryOnboardingStore()
    @State private var presentation: RootPresentation?
    /// Chosen with "Open in Feed" in a link sheet; shown in the main navigation once the sheet is gone.
    @State private var itemToOpen: Summary?
    @State private var podcastToOpen: DailyPodcast?
    @State private var checkedLaunchEducation = false
    @State private var isDropTargeted = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            switch environment.authenticationState {
            case .checking:
                ProgressView("Restoring your session…")
            case .signedOut:
                RxSignInView(
                    manager: environment.authManager,
                    appearance: RxSignInAppearance(
                        icon: .systemImage("text.quote"),
                        title: "Chippy",
                        subtitle: "Summarise anything into a link worth sharing.",
                        signInButtonTitle: "Sign in with RxLab",
                        accentColor: .indigo,
                        secondaryColor: .teal,
                        showsAnimatedBackground: true
                    ),
                    style: .native,
                    onAuthSuccess: { environment.authenticationCompleted() }
                )
                .accessibilityIdentifier("rxauth-sign-in")
            case .signedIn:
                signedInContent
                    .modifier(DailyPodcastPresentation(environment: environment))
                    .modifier(LibraryCreationPresentation(environment: environment))
                    // Dropping a file or link anywhere in the window opens New Summary with it.
                    .summaryDropDestination(isEnabled: presentation == nil) {
                        isDropTargeted = $0
                    } onFile: { file in
                        environment.pendingFile = file
                    } onLink: { url in
                        environment.pendingServiceText = url.absoluteString
                    }
                    .overlay {
                        if isDropTargeted { SummaryDropHighlight() }
                    }
            }
        }
        .tint(.indigo)
        .sheet(item: presentationBinding, onDismiss: sheetDismissed) { presentation in
            switch presentation {
            case .education(let flow):
                EducationSheet(pages: flow.pages, onAcknowledged: onboarding.acknowledge) {
                    self.presentation = nil
                }
            case .summary(let route):
                DeepLinkSheet(environment: environment, route: route) { summary in
                    itemToOpen = summary
                    presentationBinding.wrappedValue = nil
                }
                .summarySheetSize()
            case .backgroundJobs(let request):
                BackgroundJobsSheet(api: environment.api, selectedID: request.selectedID) { podcast in
                    podcastToOpen = podcast
                    presentationBinding.wrappedValue = nil
                }
                .id(request.id)
            case .topUp:
                SummaryCreditsSheet(environment: environment, opensTopUps: true)
            case .newSummary(let request):
                NewSummarySheet(environment: environment, initialText: request.text, initialFile: request.file)
            }
        }
        .task { presentNext() }
        .onChange(of: environment.authenticationState) { _, state in
            if state == .signedIn {
                presentNext()
            } else {
                navigation = MainNavigationState()
                environment.podcastPlayer.close()
                environment.backgroundJobsRequest = nil
                environment.libraryCreation = nil
                presentation = nil
            }
        }
        .onChange(of: environment.pendingRoute) { _, route in
            if route != nil { presentNext() }
        }
        .onChange(of: environment.podcastPlayer.isPresented) { _, presented in
            if !presented, environment.backgroundJobsRequest != nil {
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    presentNext()
                }
            }
        }
        .onChange(of: environment.backgroundJobsRequest?.id) { _, requestID in
            if case .backgroundJobs = presentation, let request = environment.backgroundJobsRequest {
                presentation = .backgroundJobs(request)
            } else if requestID != nil { presentNext() }
        }
        .onChange(of: environment.pendingTopUp) { _, pending in
            if pending { presentNext() }
        }
        .onChange(of: environment.pendingServiceText) { _, text in
            if text != nil { presentNext() }
        }
        .onChange(of: environment.pendingFile) { _, file in
            if file != nil { presentNext() }
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        #if os(visionOS)
        MainTabView(environment: environment, navigation: navigation)
            .modifier(DailyPodcastBottomInset(player: environment.podcastPlayer))

        #elseif os(macOS)
        SidebarMainView(environment: environment, navigation: navigation)
        #else
        if horizontalSizeClass == .regular {
            SidebarMainView(environment: environment, navigation: navigation)
        } else {
            MainTabView(environment: environment, navigation: navigation)
                .modifier(DailyPodcastBottomInset(player: environment.podcastPlayer, usesTabAccessory: usesPodcastTabAccessory))
        }
        #endif
    }

    private var usesPodcastTabAccessory: Bool {
        #if os(iOS)
        if #available(iOS 27.0, *) { return true }
        #endif
        return false
    }

    // A single root sheet keeps launch education and incoming summary links from competing.
    private var presentationBinding: Binding<RootPresentation?> {
        Binding(get: { presentation }, set: { value in
            if value == nil, case .summary(let route) = presentation,
               environment.pendingRoute == route
            {
                environment.pendingRoute = nil
            }
            if value == nil, case .backgroundJobs = presentation { environment.backgroundJobsRequest = nil }
            if value == nil, case .topUp = presentation { environment.pendingTopUp = false }
            presentation = value
        })
    }

    private func sheetDismissed() {
        if let podcastToOpen {
            self.podcastToOpen = nil
            environment.podcastPlayer.present(podcast: podcastToOpen)
        }
        if let itemToOpen {
            self.itemToOpen = nil
            environment.pendingLibraryItem = itemToOpen
        }
        presentNext()
    }

    private func presentNext() {
        guard environment.authenticationState == .signedIn, presentation == nil else { return }
        if let request = environment.backgroundJobsRequest {
            guard !environment.podcastPlayer.isPresented else { return }
            presentation = .backgroundJobs(request)
        } else if environment.pendingTopUp {
            presentation = .topUp
        } else if let file = environment.takePendingFile() {
            presentation = .newSummary(NewSummaryRequest(file: file))
        } else if let text = environment.pendingServiceText {
            environment.pendingServiceText = nil
            presentation = .newSummary(NewSummaryRequest(text: text))
        } else if let route = environment.pendingRoute {
            presentation = .summary(route)
        } else if !checkedLaunchEducation {
            checkedLaunchEducation = true
            let pages = onboarding.launchPages
            if !pages.isEmpty {
                presentation = .education(EducationPresentation(pages: pages))
            }
        }
    }
}

private enum RootPresentation: Identifiable {
    case education(EducationPresentation)
    case summary(AppRoute)
    case topUp
    case backgroundJobs(BackgroundJobsRequest)
    case newSummary(NewSummaryRequest)

    var id: String {
        switch self {
        case .education(let flow): "education:\(flow.id)"
        case .summary(let route): route.id
        case .topUp: "top-up"
        case .backgroundJobs(let request): "jobs:\(request.id)"
        case .newSummary(let request): "new-summary:\(request.id)"
        }
    }
}

/// Text from the Services menu, or a file or link dropped on the window or opened with the app.
/// A fresh id so repeated sends of the same text still present.
private struct NewSummaryRequest {
    let id = UUID()
    var text = ""
    var file: DroppedSummaryFile?
}

enum MainTab: Hashable {
    case discover
    case library
    case miniApps
    case likes
    case chat
    case settings
}

/// Owned above the adaptive layout switch: folding must not discard a document stack or reset
/// the user's sidebar preference when SwiftUI recreates the compact/regular containers.
@Observable
final class MainNavigationState {
    var selection: MainTab = .library
    var libraryPath: [Summary] = []
    var miniAppsPath: [Summary] = []
    var likesPath: [Summary] = []
    var columnVisibility: NavigationSplitViewVisibility = .all
    var sideAgent: ChatModel?
    var libraryAgent: ChatModel?
    var lastFocusedChat = false
    var contentSelection: MainTab = .library

    func chatModel(environment: AppEnvironment) -> ChatModel {
        if let sideAgent { return sideAgent }
        if let libraryAgent { return libraryAgent }
        let model = ChatModel(client: environment.chatClient, store: environment.chatStore)
        libraryAgent = model
        return model
    }
    #if !os(macOS)
    // Start closed on iPhone and iPad; explicit chat actions open the panel.
    var showsChat = false
    #endif
}

/// Compact-width (iPhone) layout; larger screens use `SidebarMainView` with chat as a column.
struct MainTabView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var navigation: MainNavigationState
    @Environment(\.openPodcast) private var openPodcast
    @Environment(\.openMiniApp) private var openMiniApp

    var body: some View {
        TabView(selection: $navigation.selection) {
            Tab("Feed", systemImage: "square.stack", value: MainTab.library) {
                LibraryView(environment: environment, path: $navigation.libraryPath)
            }
            Tab("Clips", systemImage: "app.badge", value: MainTab.miniApps) {
                LibraryView(environment: environment, path: $navigation.miniAppsPath, kind: .miniApp)
            }
            Tab("Likes", systemImage: "star", value: MainTab.likes) {
                LikesView(environment: environment, path: $navigation.likesPath)
            }
            Tab("Settings", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView(environment: environment)
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: MainTab.chat, role: chatTabRole) {
                ChatView(environment: environment, model: navigation.chatModel(environment: environment))
                    .id(ObjectIdentifier(navigation.chatModel(environment: environment)))
            }
        }
        #if os(iOS)
        .dailyPodcastTabAccessory(player: environment.podcastPlayer)
        #endif
        .onAppear {
            if navigation.lastFocusedChat { navigation.selection = .chat }
        }
        .onChange(of: navigation.selection) { _, selection in
            navigation.lastFocusedChat = selection == .chat
            if selection != .chat { navigation.contentSelection = selection }
        }
        .summarySearchPresentation(environment: environment, onOpenSummary: openItem)
        .environment(\.openLibraryItem, openItem)
        .onChange(of: environment.pendingLibraryItem) { _, item in
            guard let item else { return }
            environment.pendingLibraryItem = nil
            openItem(item)
        }
    }

    private func openItem(_ summary: Summary) {
        if (summary.kind == .podcast || summary.kind == .audiobook), !summary.isExpired, let openPodcast {
            openPodcast(summary)
            return
        }
        if summary.kind == .miniApp {
            navigation.selection = .miniApps
            if let openMiniApp { openMiniApp(summary) } else { navigation.miniAppsPath = [summary] }
        } else {
            navigation.selection = .library
            navigation.libraryPath = [summary]
        }
    }

    /// iOS 27 sets the chat tab apart from the others as the prominent tab.
    private var chatTabRole: TabRole? {
        if #available(iOS 27.0, *) {
            if #available(anyAppleOS 27.0, *) {
                return .prominent
            } else {
                // Fallback on earlier versions
            }
        }
        return nil
    }
}
