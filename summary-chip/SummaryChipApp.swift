import AppIntents
import RxAuthSwift
import SummaryKit
import SwiftUI

@main
struct SummaryChipApp: App {
    @State private var environment: AppEnvironment

    init() {
        let environment = AppEnvironment.live()
        _environment = State(initialValue: environment)
        // Siri / Shortcuts intents run in this process and share the signed-in environment.
        AppDependencyManager.shared.add(dependency: environment)
    }

    var body: some Scene {
        WindowGroup {
            appContent
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 620)
                #endif
                .environment(\.summaryAssetLoader, environment.assetLoader)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--preview-education") { return }
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
        .commands { SummaryMacCommands() }
        #endif
    }

    @ViewBuilder
    private var appContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-education") {
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
