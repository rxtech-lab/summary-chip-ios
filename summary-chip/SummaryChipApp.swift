import AppIntents
import RxAuthSwift
import SummaryKit
import SwiftUI

@main
struct SummaryChipApp: App {
    @State private var environment: AppEnvironment
    #if os(macOS)
    private let serviceProvider: SummaryServiceProvider
    #endif

    init() {
        let environment = AppEnvironment.live()
        _environment = State(initialValue: environment)
        // Siri / Shortcuts intents run in this process and share the signed-in environment.
        AppDependencyManager.shared.add(dependency: environment)
        #if os(macOS)
        serviceProvider = SummaryServiceProvider(environment: environment)
        serviceProvider.register()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            appContent
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 620)
                #endif
                .environment(\.summaryAssetLoader, environment.assetLoader)
                .task {
                    #if os(macOS)
                    UpdateService.shared.start()
                    #endif
                    #if DEBUG
                    #if os(iOS)
                    if ProcessInfo.processInfo.arguments.contains("--preview-local-file") { return }
                    #endif
                    if ProcessInfo.processInfo.arguments.contains("--preview-education") { return }
                    if ProcessInfo.processInfo.arguments.contains("--preview-credits") { return }
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
                .onReceive(NotificationCenter.default.publisher(for: .rxAuthSessionExpired)) { _ in
                    Task { await environment.sessionExpired() }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
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
        if ProcessInfo.processInfo.arguments.contains("--preview-credits") {
            CreditsPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-education") {
            OnboardingPreviewHost()
        } else {
            #if os(macOS)
            if ProcessInfo.processInfo.arguments.contains("--preview-mac") {
                SidebarMainView(environment: environment)
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
