import SummaryKit
import SwiftUI

/// Signed-out → notice; otherwise source preview → options → generating → result.
struct ShareRootView: View {
    let inputItems: [Any]
    let finish: () -> Void
    let cancel: () -> Void
    let openURL: (URL) -> Void

    private enum Phase {
        case loading
        case signedOut
        case failed(String)
        case ready(SummaryInput)
    }

    @State private var phase: Phase = .loading
    @State private var configuration = SummaryConfiguration.live()
    @State private var broker: SharedTokenBroker?
    @State private var api: SummaryAPIClient?
    @State private var loader: SummaryAssetLoader = .anonymous
    @State private var sourceFile: URL?
    @State private var sourceFilename: String?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                NavigationStack {
                    Color.clear.overlay { ActionStatusOverlay("Reading what you shared…", isWorking: true) }
                        .toolbar { cancelItem }
                }
            case .signedOut:
                NavigationStack {
                    SignedOutNotice()
                        .navigationTitle("Chippy")
                        .summaryInlineNavigationTitle()
                        .toolbar { cancelItem }
                }
            case .failed(let message):
                NavigationStack {
                    Color.clear.statusAlert("Couldn't Read Shared Item", message: message, onDismiss: cancel)
                        .toolbar { cancelItem }
                }
            case .ready(let input):
                if let api {
                    SummaryCreationFlow(api: api, input: input, sourceFile: sourceFile, sourceFilename: sourceFilename, title: "Chippy", onCancel: cancel) { summary in
                        ShareResultView(summary: summary, openInApp: { openURL(SummaryLink.openInAppURL(summaryID: summary.id)) }, done: finish)
                    }
                }
            }
        }
        .environment(\.summaryAssetLoader, loader)
        .task { await prepare() }
    }

    private var cancelItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel, action: cancel)
        }
    }

    private func prepare() async {
        let broker = SharedTokenBroker.live(configuration: configuration)
        guard await broker.hasSession() else {
            phase = .signedOut
            return
        }
        self.broker = broker
        api = SummaryAPIClient(baseURL: configuration.apiBaseURL, tokenProvider: broker)
        loader = SummaryAssetLoader(tokenProvider: broker, cacheLimitBytes: 8 * 1024 * 1024)
        do {
            let raw = try await SharePayloadLoader.loadRaw(inputItems: inputItems)
            guard let input = ShareClassifier.classify(raw) else { throw SharePayloadError.noSupportedItems }
            sourceFile = raw.pdfFile ?? raw.localFile
            sourceFilename = raw.pdfFilename ?? raw.localFilename
            phase = .ready(input)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct ShareResultView: View {
    let summary: Summary
    let openInApp: () -> Void
    let done: () -> Void

    var body: some View {
        List {
            Section {
                SummaryCardView(summary: summary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
            }
            ShareActionsSection(summary: summary)
            Section {
                Button(action: openInApp) {
                    Label("Open in Chippy", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).fontWeight(.semibold)
            }
        }
    }
}
