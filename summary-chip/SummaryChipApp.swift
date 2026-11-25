import AppIntents
import RxAuthSwift
import SummaryKit
import SwiftUI

@main
struct SummaryChipApp: App {
    #if os(iOS) || os(visionOS)
    @UIApplicationDelegateAdaptor(SummaryAppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(SummaryAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var environment: AppEnvironment
    #if os(macOS)
    private let serviceProvider: SummaryServiceProvider
    #endif

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let environment: AppEnvironment
        if let local = Self.resumeTestEnvironment() {
            environment = local
        } else if LikesPreviewFixture.isEnabled {
            environment = LikesPreviewFixture.environment()
        } else if arguments.contains("--preview-chat-stream") {
            environment = LikesPreviewFixture.signedInEnvironment()
        } else {
            environment = AppEnvironment.live()
        }
        if arguments.contains("--preview-flowcy-subscription") {
            environment.subscription.enablePurchasePreview(price: "$12.99")
        }
        #else
        let environment = AppEnvironment.live()
        #endif
        _environment = State(initialValue: environment)
        SummaryNotifications.shared.configure(environment: environment)
        // Siri / Shortcuts intents run in this process and share the signed-in environment.
        AppDependencyManager.shared.add(dependency: environment)
        #if os(macOS)
        serviceProvider = SummaryServiceProvider(environment: environment)
        serviceProvider.register()
        #endif
    }

    #if DEBUG
    /// The cross-platform UI test creates an isolated family through the loopback E2E issuer.
    /// Keep its short-lived token in memory and restrict the API origin to loopback.
    private static func resumeTestEnvironment() -> AppEnvironment? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--preview-resume-http"), let token = process.environment["RESUME_TEST_TOKEN"] else { return nil }
        let bundle = SharedTokenBundle(accessToken: token, refreshToken: nil, idToken: nil,
                                      expiresAt: .now.addingTimeInterval(600), subject: "resume-local-owner")
        return AppEnvironment.live(configuration: .init(apiBaseURL: URL(string: "http://127.0.0.1:3180")!),
                                   vault: InMemoryTokenVault(bundle), session: URLSession(configuration: .ephemeral), authenticationState: .signedIn)
    }
    #endif

    var body: some Scene {
        // Keep the main window first: macOS uses the first scene for the default launch.
        WindowGroup(id: "main") {
            appContent
                .miniAppPresenter(environment: environment)
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 620)
                #endif
                .environment(\.summaryAssetLoader, environment.assetLoader)
                #if os(macOS)
                .appUpdateAlert { UpdateService.shared.checkForUpdates() }
                #else
                .appUpdateAlert()
                #endif
                .task {
                    #if os(macOS)
                    UpdateService.shared.start()
                    #endif
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--preview-mini-app") || ProcessInfo.processInfo.arguments.contains("--preview-mini-app-loading") { return }
                    if ProcessInfo.processInfo.arguments.contains("--preview-resume-http") { return }
                    if ProcessInfo.processInfo.arguments.contains("--preview-chat-stream") { return }
                    if ProcessInfo.processInfo.arguments.contains("--preview-todo") || ProcessInfo.processInfo.arguments.contains("--preview-graph") { return }
                    #if os(iOS) || os(visionOS)
                    if ProcessInfo.processInfo.arguments.contains("--preview-local-file") { return }
                    #endif
                    if ProcessInfo.processInfo.arguments.contains("--preview-education") { return }
                    if ProcessInfo.processInfo.arguments.contains("--preview-flowcy-subscription") { return }
                    if ProcessInfo.processInfo.arguments.contains("--preview-paper-editor") { return }
                    if ProcessInfo.processInfo.arguments.contains("--preview-paper-export") { return }
                    if LikesPreviewFixture.isEnabled { return }
                    #if os(macOS)
                    if ProcessInfo.processInfo.arguments.contains("--preview-mac") { return }
                    #endif
                    #endif
                    await environment.start()
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { environment.handleIncomingURL(url) }
                }
                .onOpenURL { url in environment.handleIncomingURL(url) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await environment.refreshSubscription()
                            await SummaryNotifications.shared.synchronize()
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: FlowcySubscription.accessRequired)) { _ in
                    guard environment.subscription.isActive else { return }
                    Task { await environment.refreshSubscription() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .rxAuthSessionExpired)) { _ in
                    Task { await environment.sessionExpired() }
                }
        }
        #if os(visionOS)
        .windowStyle(.plain)
        .defaultSize(width: 1100, height: 760)
        #endif
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #if DEBUG
        .defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--preview-resume-http") ? .presented : .automatic)
        .restorationBehavior(ProcessInfo.processInfo.arguments.contains("--preview-resume-http") ? .disabled : .automatic)
        #endif
        .commands {
            SummaryMacCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
                    UpdateService.shared.checkForUpdates()
                }
                Button("Software Update Settings…", systemImage: "gearshape") {
                    UpdateService.shared.showSettings()
                }
            }
        }
        #endif
        #if os(visionOS)
        SpatialGraphWindows(environment: environment)
        #endif
        #if os(macOS)
        WindowGroup("Discover", id: "marketplace") {
            MarketplaceScreen(environment: environment).frame(minWidth: 600, minHeight: 600)
        }
        MiniAppWindow(environment: environment)
        #endif
    }

    @ViewBuilder
    private var appContent: some View {
        #if DEBUG
        #if os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--preview-local-file") {
            LocalFilePreviewHost()
        } else {
            standardAppContent
        }
        #else
        standardAppContent
        #endif
        #else
        ContentView(environment: environment)
        #endif
    }

    @ViewBuilder
    private var standardAppContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-flowcy-subscription") {
            FlowcySubscriptionView(environment: environment)
        } else if ProcessInfo.processInfo.arguments.contains("--preview-resume-http"), let family = ProcessInfo.processInfo.environment["RESUME_TEST_FAMILY"] {
            NavigationStack { ResumeDetailView(environment: environment, id: family) }
        } else if ProcessInfo.processInfo.arguments.contains("--preview-todo") {
            TodoPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-graph") {
            GraphPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-mini-app-loading") {
            MiniAppLoadingPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-mini-app") {
            MiniAppPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-chat-stream") {
            ChatView(environment: environment, model: ChatModel(client: environment.chatClient, store: .init(directory: nil)))
        } else if ProcessInfo.processInfo.arguments.contains("--preview-education") {
            OnboardingPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-paper-editor") {
            PaperEditorPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-paper-export") {
            PaperExportPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-paper-reader") {
            PaperReaderPreviewHost()
        } else {
            #if os(macOS)
            if ProcessInfo.processInfo.arguments.contains("--preview-mac") {
                SidebarMainView(environment: environment, navigation: MainNavigationState())
            } else {
                ContentView(environment: environment)
            }
            #else
            ContentView(environment: environment)
            #endif
        }
        #else
        ContentView(environment: environment)
        #endif
    }
}
