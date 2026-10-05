import RxAuthSwift
import RxAuthSwiftUI
import SummaryKit
import SwiftUI

struct ContentView: View {
    @Bindable var environment: AppEnvironment
    @State private var onboarding = SummaryOnboardingStore()
    @State private var presentation: RootPresentation?
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
        .sheet(item: presentationBinding, onDismiss: presentNext) { presentation in
            switch presentation {
            case .education(let flow):
                EducationSheet(pages: flow.pages, onAcknowledged: onboarding.acknowledge) {
                    self.presentation = nil
                }
            case .summary(let route):
                DeepLinkSheet(environment: environment, route: route)
                    .summarySheetSize()
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
                presentation = nil
            }
        }
        .onChange(of: environment.pendingRoute) { _, route in
            if route != nil { presentNext() }
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

    // A single root sheet keeps launch education and incoming summary links from competing.
    private var presentationBinding: Binding<RootPresentation?> {
        Binding(get: { presentation }, set: { value in
            if value == nil, case .summary(let route) = presentation,
               environment.pendingRoute == route
            {
                environment.pendingRoute = nil
            }
            if value == nil, case .topUp = presentation { environment.pendingTopUp = false }
            presentation = value
        })
    }

    private func presentNext() {
        guard environment.authenticationState == .signedIn, presentation == nil else { return }
        if environment.pendingTopUp {
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
    case newSummary(NewSummaryRequest)

    var id: String {
        switch self {
        case .education(let flow): "education:\(flow.id)"
        case .summary(let route): route.id
        case .topUp: "top-up"
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
    case library
    case likes
    case chat
    case settings
}

/// Compact-width (iPhone) layout; larger screens use `SidebarMainView` with chat as a column.
struct MainTabView: View {
    @Bindable var environment: AppEnvironment
    @State private var selection: MainTab = .library
    @State private var libraryPath: [Summary] = []
    @State private var likesPath: [Summary] = []

    var body: some View {
        TabView(selection: $selection) {
            Tab("Library", systemImage: "square.stack", value: MainTab.library) {
                LibraryView(environment: environment, path: $libraryPath)
            }
            Tab("Likes", systemImage: "star", value: MainTab.likes) {
                LikesView(environment: environment, path: $likesPath)
            }
            Tab("Settings", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView(environment: environment)
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: MainTab.chat, role: chatTabRole) {
                ChatView(environment: environment)
            }
        }
        .summarySearchPresentation(environment: environment) { summary in
            selection = .library
            libraryPath = [summary]
        }
        .environment(\.openLibraryItem, { summary in
            selection = .library
            libraryPath = [summary]
        })
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
