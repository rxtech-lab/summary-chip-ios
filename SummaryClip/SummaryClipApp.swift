import StoreKit
import SummaryKit
import SwiftUI

/// App Clip for `https://summary.rxlab.app/s/<slug>`. Anonymous: only `/api/public/*`.
@main
struct SummaryClipApp: App {
    @State private var model = ClipModel()

    var body: some Scene {
        WindowGroup {
            ClipRootView(model: model)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.open(url) }
                }
                .onOpenURL { url in model.open(url) }
        }
    }
}

@Observable
final class ClipModel {
    enum State: Equatable {
        case waiting
        case loading
        case loaded(Summary)
        case unavailable
        case failed(String)
    }

    let configuration = SummaryConfiguration.live()
    private(set) var state: State = .waiting
    private(set) var slug: String?
    private var task: Task<Void, Never>?

    func open(_ url: URL) {
        guard let slug = SummaryLink.slug(from: url, siteHost: configuration.siteHost) else {
            state = .unavailable
            return
        }
        guard slug != self.slug || !(state.isLoaded) else { return }
        self.slug = slug
        load()
    }

    func load() {
        guard let slug else { return }
        task?.cancel()
        state = .loading
        let client = PublicSummaryClient(baseURL: configuration.apiBaseURL)
        task = Task {
            do {
                let summary = try await client.summary(slug: slug)
                state = .loaded(summary)
            } catch let error as SummaryAPIError where error.isNotFound {
                state = .unavailable
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

private extension ClipModel.State {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

struct ClipRootView: View {
    let model: ClipModel
    @State private var showsAppOverlay = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Summary Chip")
                .navigationBarTitleDisplayMode(.inline)
        }
        .appStoreOverlay(isPresented: $showsAppOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .waiting, .loading:
            ProgressView("Loading summary…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let summary):
            ScrollView {
                VStack(spacing: 16) {
                    SummaryDetailContent(summary: summary)
                    getAppCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
        case .unavailable:
            ContentUnavailableView {
                Label("This summary isn't available", systemImage: "lock.circle")
            } description: {
                Text("Its owner made it private, or the link has expired.")
            } actions: {
                Button("Get Summary Chip") { showsAppOverlay = true }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load the summary", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.load() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var getAppCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Make your own summaries", systemImage: "sparkles")
                .font(.headline)
            Text("Summary Chip turns any web page, PDF or text into a short summary with a beautiful link preview.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showsAppOverlay = true
            } label: {
                Text("Get the full app")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}
