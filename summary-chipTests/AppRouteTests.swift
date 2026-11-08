import Foundation
import SummaryKit
import Testing
@testable import summary_chip

@MainActor
@Suite struct AppRouteTests {
    @Test func universalLinkBecomesSlugRoute() {
        let route = AppRoute(url: URL(string: "https://summary.rxlab.app/s/a1B2c3D4e5")!, siteHost: "summary.rxlab.app")
        #expect(route == .slug("a1B2c3D4e5"))
    }

    @Test func openInAppLinkBecomesIDRoute() {
        let route = AppRoute(url: SummaryLink.openInAppURL(summaryID: "abc"), siteHost: "summary.rxlab.app")
        #expect(route == .summaryID("abc"))
    }

    @Test func tripLinkBecomesTripRoute() {
        let route = AppRoute(url: SummaryLink.openTripURL(tripID: "trip_1"), siteHost: "summary.rxlab.app")
        #expect(route == .tripID("trip_1"))
        #expect(route?.id == "trip:trip_1")
    }

    @Test func oauthCallbackIsIgnored() {
        #expect(AppRoute(url: URL(string: "summarychip://oauth/callback?code=1")!, siteHost: "summary.rxlab.app") == nil)
    }

    @Test func chatHistoryFoldsToolResultsIntoText() {
        var assistant = ChatEntry(id: "2", role: .assistant, text: "Found one.")
        assistant.tools = [ChatToolActivity(id: "c", toolName: "searchSummaries", label: "", isRunning: false, references: [
            SummaryReference(id: "s1", slug: "x", title: "Chips", summary: nil, category: nil, tags: [], siteName: nil, sourceUrl: nil, shareUrl: URL(string: "https://summary.rxlab.app/s/x"), ogImageUrl: nil, createdAt: nil, viewedAt: nil),
        ])]
        let messages = ChatModel.uiMessages(from: [ChatEntry(id: "1", role: .user, text: "chips?"), assistant, ChatEntry(id: "3", role: .assistant, text: "")])
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[1].parts.first?.text.contains("Chips (id: s1, https://summary.rxlab.app/s/x)") == true)
    }
}

#if os(iOS) && DEBUG
import SwiftUI
import UIKit

/// Mount the real root and change its size class, so NavigationStack/SplitView lifecycle writes
/// are exercised as well as the state shared between the two layouts.
@MainActor
@Suite(.serialized) struct AdaptiveNavigationTests {
    @Test(arguments: [MainTab.library, .likes, .miniApps])
    func foldRoundTripKeepsDocumentAndSidebar(section: MainTab) async throws {
        let environment = LikesPreviewFixture.environment()
        let navigation = MainNavigationState()
        let document = try JSONDecoder().decode(Summary.self, from: Data("""
        {"id":"fold-document","slug":"fold-document","title":"Fold document",
         "shareUrl":"https://summary.rxlab.app/s/fold-document","createdAt":0}
        """.utf8))
        let root = ContentView(environment: environment, navigation: navigation)
        let host = UIHostingController(rootView: root.environment(\.horizontalSizeClass, .compact))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))

        navigation.selection = section
        switch section {
        case .library: navigation.libraryPath = [document]
        case .likes: navigation.likesPath = [document]
        case .miniApps: navigation.miniAppsPath = [document]
        default: Issue.record("Unexpected test section")
        }
        try await Task.sleep(for: .milliseconds(300))

        // Exercise both sidebar preferences and repeat the complete fold/unfold cycle.
        for visibility in [NavigationSplitViewVisibility.detailOnly, .all] {
            navigation.columnVisibility = visibility
            navigation.showsChat = false
            for sizeClass in [UserInterfaceSizeClass.regular, .compact, .regular, .compact] {
                host.rootView = root.environment(\.horizontalSizeClass, sizeClass)
                try await Task.sleep(for: .milliseconds(300))
                #expect(navigation.selection == section)
                let path = switch section {
                case .likes: navigation.likesPath
                case .miniApps: navigation.miniAppsPath
                default: navigation.libraryPath
                }
                #expect(path.map(\.id) == [document.id])
                #expect(navigation.columnVisibility == visibility)
                #expect(!navigation.showsChat)
            }
        }
    }
}
#endif
