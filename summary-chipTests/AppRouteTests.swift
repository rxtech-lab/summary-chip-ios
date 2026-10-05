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
