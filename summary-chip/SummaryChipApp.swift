import RxAuthSwift
import SummaryKit
import SwiftUI

@main
struct SummaryChipApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .environment(\.summaryAssetLoader, environment.assetLoader)
                .task { await environment.start() }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { environment.handleIncomingURL(url) }
                }
                .onOpenURL { url in environment.handleIncomingURL(url) }
                .onReceive(NotificationCenter.default.publisher(for: .rxAuthSessionExpired)) { _ in
                    Task { await environment.sessionExpired() }
                }
        }
    }
}
