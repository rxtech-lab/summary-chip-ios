import Messages
import Observation
import SummaryKit
import SwiftUI

@Observable
final class MessagesState {
    let configuration = SummaryConfiguration.live()
    let broker: SharedTokenBroker
    let api: SummaryAPIClient
    let assetLoader: SummaryAssetLoader

    var presentationStyle: MSMessagesAppPresentationStyle = .compact
    private(set) var isSignedIn: Bool?
    private(set) var recent: [Summary] = RecentSummariesCache.load()
    private(set) var recentError: String?
    /// Text the expanded flow starts with (a pasted link); changing `flowID` restarts the flow.
    var pendingText = ""
    private(set) var flowID = UUID()

    @ObservationIgnored var requestStyle: (MSMessagesAppPresentationStyle) -> Void = { _ in }
    @ObservationIgnored var insertLink: (URL) -> Void = { _ in }
    @ObservationIgnored var insertImage: (URL, URL) -> Void = { _, _ in }
    @ObservationIgnored var openApp: (URL) -> Void = { _ in }

    init() {
        broker = SharedTokenBroker.live(configuration: configuration)
        api = SummaryAPIClient(baseURL: configuration.apiBaseURL, tokenProvider: broker)
        assetLoader = SummaryAssetLoader(tokenProvider: broker, cacheLimitBytes: 16 * 1024 * 1024)
    }

    func refresh() async {
        let signedIn = await broker.hasSession()
        isSignedIn = signedIn
        guard signedIn else { return }
        do {
            let page = try await api.listSummaries(SummaryListQuery(limit: 5))
            recent = Array(page.items.prefix(5))
            recentError = nil
            RecentSummariesCache.save(recent)
        } catch let error as SummaryAPIError where error.isUnauthorized {
            isSignedIn = false
        } catch {
            recentError = error.localizedDescription
        }
    }

    func startNew(with text: String = "") {
        pendingText = text
        flowID = UUID()
        requestStyle(.expanded)
    }

    func resetFlow() {
        pendingText = ""
        flowID = UUID()
    }

    func created(_ summary: Summary) {
        recent.removeAll { $0.id == summary.id }
        recent.insert(summary, at: 0)
        recent = Array(recent.prefix(5))
        RecentSummariesCache.save(recent)
    }
}
