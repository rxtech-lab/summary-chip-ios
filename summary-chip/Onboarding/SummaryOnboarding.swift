import Foundation
import Observation

struct EducationPage: Identifiable, Equatable {
    enum Kind: Equatable { case welcome, feature }
    let id: String
    let kind: Kind
    let title: String
    let message: String
    let imageName: String

    private static var safariMessage: String {
        #if os(macOS)
        String(localized: "Open a page in Safari, click Share, and choose Chippy. The share extension turns the page into a summary without leaving your browser. You can also paste a link or choose a PDF in New Summary.")
        #else
        String(localized: "Open a page in Safari, tap Share, and choose Chippy. The share extension turns the page into a summary without leaving your browser.")
        #endif
    }

    static let welcome: [Self] = [
        .init(id: "welcome-safari", kind: .welcome,
              title: String(localized: "From Safari to a summary"),
              message: safariMessage,
              imageName: "WelcomeSafari"),
        .init(id: "welcome-siri", kind: .welcome,
              title: String(localized: "Just ask Siri"),
              message: String(localized: "Say “Add a summary in Chippy”, then give Siri a link or some text. Your summary is saved to your Library using your saved options."),
              imageName: "WelcomeSiri"),
        .init(id: "welcome-sharing", kind: .welcome,
              title: String(localized: "Share on your terms"),
              message: String(localized: "Send a summary as a link. Choose how long it stays available, or make it private. Open a summary’s Edit Sharing sheet to change visibility and link expiry."),
              imageName: "WelcomeSharing")
    ]

    // Append new features with permanent IDs. Read state survives upgrades and sign-in changes.
    static let features: [Self] = [
        .init(id: "siri-summary-v1", kind: .feature,
              title: String(localized: "Your next summary, with Siri"),
              message: String(localized: "Add Summary now works with Siri and Shortcuts. Summarise a link or text, see the finished card, and find it in your Library. Use the action in your own shortcuts, too."),
              imageName: "WelcomeSiri"),
        .init(id: "mcp-server-v1", kind: .feature,
              title: String(localized: "Connect your AI agents"),
              message: String(localized: "Chippy now supports MCP. Let AI agents add summaries, search your Library, and list your saved chips from anywhere. Open Settings → MCP Server to create an API key and copy your agent’s connection setup. Chippy doesn’t need to be open."),
              imageName: "FeatureMCP")
    ]
}

struct EducationPresentation: Identifiable {
    let id = UUID()
    let pages: [EducationPage]
}

@MainActor
@Observable
final class SummaryOnboardingStore {
    static let welcomeKey = "summary-chip.welcome.v1.seen"
    static let readIDsKey = "summary-chip.features.v1.read-ids"
    private let defaults: UserDefaults
    private(set) var hasSeenWelcome: Bool
    private(set) var readIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasSeenWelcome = defaults.bool(forKey: Self.welcomeKey)
        readIDs = Set(defaults.stringArray(forKey: Self.readIDsKey) ?? [])
    }

    var unreadFeatures: [EducationPage] { unreadFeatures(from: EducationPage.features) }

    func unreadFeatures(from pages: [EducationPage]) -> [EducationPage] {
        pages.filter { !readIDs.contains($0.id) }
    }

    var launchPages: [EducationPage] {
        (hasSeenWelcome ? [] : EducationPage.welcome) + unreadFeatures
    }

    func acknowledge(_ page: EducationPage) {
        if page.kind == .welcome {
            guard page.id == EducationPage.welcome.last?.id else { return }
            hasSeenWelcome = true
            defaults.set(true, forKey: Self.welcomeKey)
        } else {
            readIDs.insert(page.id)
            defaults.set(readIDs.sorted(), forKey: Self.readIDsKey)
        }
    }
}
