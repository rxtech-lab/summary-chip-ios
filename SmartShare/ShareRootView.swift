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

    var body: some View {
        Group {
            switch phase {
            case .loading:
                NavigationStack {
                    ProgressView("Reading what you shared…")
                        .toolbar { cancelItem }
                }
            case .signedOut:
                NavigationStack {
                    SignedOutNotice()
                        .navigationTitle("Summary Chip")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { cancelItem }
                }
            case .failed(let message):
                NavigationStack {
                    ContentUnavailableView("Can't summarise this", systemImage: "questionmark.folder", description: Text(message))
                        .toolbar { cancelItem }
                }
            case .ready(let input):
                if let api {
                    SummaryCreationFlow(api: api, input: input, title: "Summary Chip", onCancel: cancel) { summary in
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
            phase = .ready(try await SharePayloadLoader.load(inputItems: inputItems))
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
                    Label("Open in Summary Chip", systemImage: "arrow.up.forward.app")
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
