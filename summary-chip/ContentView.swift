import RxAuthSwift
import RxAuthSwiftUI
import SummaryKit
import SwiftUI

struct ContentView: View {
    @Bindable var environment: AppEnvironment
    @State private var onboarding = SummaryOnboardingStore()
    @State private var presentation: RootPresentation?
    @State private var checkedLaunchEducation = false
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
                #if os(macOS)
                SidebarMainView(environment: environment)
                #else
                if horizontalSizeClass == .regular {
                    SidebarMainView(environment: environment)
                } else {
                    MainTabView(environment: environment)
                }
                #endif
            }
        }
        .tint(.indigo)
        .sheet(item: presentationBinding, onDismiss: presentNext) { presentation in
            switch presentation {
            case .education(let flow):
                EducationSheet(pages: flow.pages, onAcknowledged: onboarding.acknowledge) {
                    self.presentation = nil
                }
            case .summary(let route):
                DeepLinkSheet(environment: environment, route: route)
                    .summarySheetSize()
            }
        }
        .task { presentNext() }
        .onChange(of: environment.authenticationState) { _, state in
            if state == .signedIn {
                presentNext()
            } else {
                presentation = nil
            }
        }
        .onChange(of: environment.pendingRoute) { _, route in
            if route != nil { presentNext() }
        }
    }

    // A single root sheet keeps launch education and incoming summary links from competing.
    private var presentationBinding: Binding<RootPresentation?> {
        Binding(get: { presentation }, set: { value in
            if value == nil, case .summary(let route) = presentation,
               environment.pendingRoute == route {
                environment.pendingRoute = nil
            }
            presentation = value
        })
    }

    private func presentNext() {
        guard environment.authenticationState == .signedIn, presentation == nil else { return }
        if let route = environment.pendingRoute {
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

    var id: String {
        switch self {
        case .education(let flow): "education:\(flow.id)"
        case .summary(let route): route.id
        }
    }
}

enum MainTab: Hashable {
    case library
    case chat
    case settings
}

/// Compact-width (iPhone) layout; larger screens use `SidebarMainView` with chat as a column.
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
        }
        .summarySearchPresentation(environment: environment)
    }
}
