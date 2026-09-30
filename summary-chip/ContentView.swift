import RxAuthSwift
import RxAuthSwiftUI
import SummaryKit
import SwiftUI

struct ContentView: View {
    @Bindable var environment: AppEnvironment

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
                        title: "Summary Chip",
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
                MainTabView(environment: environment)
            }
        }
        .tint(.indigo)
    }
}

enum MainTab: Hashable {
    case library
    case chat
    case settings
    case search
}

struct MainTabView: View {
    @Bindable var environment: AppEnvironment
    @State private var selection: MainTab = .library

    var body: some View {
        TabView(selection: $selection) {
            Tab("Library", systemImage: "square.stack", value: MainTab.library) {
                LibraryView(environment: environment)
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: MainTab.chat) {
                ChatView(environment: environment)
            }
            Tab("Settings", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView(environment: environment)
            }
            Tab(value: MainTab.search, role: .search) {
                SearchView(environment: environment)
            }
        }
        .sheet(item: $environment.pendingRoute) { route in
            DeepLinkSheet(environment: environment, route: route)
        }
    }
}
