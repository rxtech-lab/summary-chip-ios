import AppIntents
import SummaryKit
import SwiftUI

/// "Hey Siri, add a summary in Summary Chip" — summarises a link or some text in the background
/// with the user's saved generation options, then shows the finished card.
struct AddSummaryIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Add Summary"
    static let description = IntentDescription(
        "Summarise a web link or some text into a shareable card.",
        categoryName: "Summaries",
        searchKeywords: ["summarise", "summarize", "link", "article", "text"]
    )
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Link or Text",
        description: "A web link, or any text you want summarised.",
        inputOptions: String.IntentInputOptions(capitalizationType: .none, multiline: true, autocorrect: false),
        requestValueDialog: "What would you like to summarise?"
    )
    var content: String

    @Dependency private var environment: AppEnvironment

    static var parameterSummary: some ParameterSummary {
        Summary("Summarise \(\.$content)")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<SummaryEntity> & ProvidesDialog & ShowsSnippetView {
        guard let input = ShareClassifier.classify(typed: content) else {
            throw $content.needsValueError("What would you like to summarise?")
        }
        guard await environment.tokenBroker.hasSession() else { throw AddSummaryIntentError.notSignedIn }

        // Generation can take ~90 s, past the ~30 s background limit; iOS 27 extends it.
        let api = environment.api
        let progress = progress
        let summary: SummaryKit.Summary
        if #available(iOS 27.0, macOS 27.0, *) {
            summary = try await performBackgroundTask { @Sendable in try await Self.createSummary(from: input, api: api, progress: progress) }
        } else {
            summary = try await Self.createSummary(from: input, api: api, progress: progress)
        }
        environment.library.insert(summary)

        return .result(
            value: SummaryEntity(summary),
            dialog: "“\(summary.title)” is ready to share.",
            view: SummaryCardView(summary: summary)
                .environment(\.summaryAssetLoader, environment.assetLoader)
                .padding()
        )
    }

    private static func createSummary(from input: SummaryInput, api: SummaryAPIClient, progress: Progress) async throws -> SummaryKit.Summary {
        // Typed input is never a PDF, so there is no upload stage.
        let stages = GenerationStage.allCases.filter { $0 != .uploading }
        progress.totalUnitCount = Int64(stages.count)
        let ticker = Task { await reportStages(stages, to: progress) }
        defer { ticker.cancel() }
        do {
            let summary = try await api.createSummary(from: input, options: GenerationOptionsStore.load())
            progress.completedUnitCount = progress.totalUnitCount
            return summary
        } catch let error as SummaryAPIError where error.isUnauthorized {
            throw AddSummaryIntentError.notSignedIn
        }
    }

    /// The server gives no progress, so step through the same estimated stages as the app.
    private static func reportStages(_ stages: [GenerationStage], to progress: Progress) async {
        let start = ContinuousClock.now
        for (index, stage) in stages.enumerated() {
            try? await Task.sleep(until: start + .seconds(stage.estimatedSeconds))
            if Task.isCancelled { return }
            progress.completedUnitCount = Int64(index)
            progress.localizedDescription = stage.title
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension AddSummaryIntent: LongRunningIntent {}

enum AddSummaryIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: "Open Summary Chip and sign in first."
        }
    }
}

/// Opens a summary in the app, e.g. the one "Add Summary" just made.
struct OpenSummaryIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Summary"
    static let description = IntentDescription("Opens a summary in Summary Chip.", categoryName: "Summaries")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Summary")
    var target: SummaryEntity

    @Dependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult {
        environment.pendingRoute = .summaryID(target.id)
        return .result()
    }
}

struct SummaryChipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddSummaryIntent(),
            phrases: [
                "Add a summary in \(.applicationName)",
                "Add a \(.applicationName) summary",
                "Summarise with \(.applicationName)",
                "Summarize with \(.applicationName)",
                "New summary in \(.applicationName)",
            ],
            shortTitle: "Add Summary",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenSummaryIntent(),
            phrases: [
                "Open a summary in \(.applicationName)",
                "Show my \(.applicationName) summaries",
            ],
            shortTitle: "Open Summary",
            systemImageName: "doc.text"
        )
    }
}
