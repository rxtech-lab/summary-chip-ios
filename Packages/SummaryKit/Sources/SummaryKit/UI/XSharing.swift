import SwiftUI

public struct XSharingMenu<Actions: View>: View {
    private let onShareToX: () -> Void
    private let actions: Actions

    public init(onShareToX: @escaping () -> Void, @ViewBuilder actions: () -> Actions) {
        self.onShareToX = onShareToX
        self.actions = actions()
    }

    public var body: some View {
        Menu {
            actions
            Button("Share to X", systemImage: "arrow.up.forward", action: onShareToX)
                .accessibilityIdentifier("share-to-x")
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

public struct XSharingRequest: Identifiable, Sendable {
    public let id = UUID()
    let summary: Summary?
    let podcast: DailyPodcast?

    public init(summary: Summary) { self.summary = summary; podcast = nil }
    public init(podcast: DailyPodcast) { summary = nil; self.podcast = podcast }
}

public extension View {
    func xSharing(_ request: Binding<XSharingRequest?>, api: SummaryAPIClient) -> some View {
        modifier(XSharingModifier(request: request, api: api))
    }
}

private struct XSharingModifier: ViewModifier {
    @Binding var request: XSharingRequest?
    let api: SummaryAPIClient
    @Environment(\.openURL) private var openURL
    @State private var error: String?
    @State private var opened = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if request != nil {
                    ProgressView("Preparing X post…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task(id: request?.id) { await prepare() }
            .alert("Couldn't Share to X", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.selection, trigger: request?.id)
            .sensoryFeedback(.success, trigger: opened)
            .sensoryFeedback(.error, trigger: error)
    }

    private func prepare() async {
        guard let request else { return }
        defer { if self.request?.id == request.id { self.request = nil } }
        do {
            var podcast = request.podcast
            if let summary = request.summary, summary.kind == .podcast {
                podcast = try await api.libraryPodcast(summaryID: summary.id)
            }
            let draft: XPostDraft
            if let podcast {
                var sources: [Summary] = []
                for id in podcast.sourceChipIDs {
                    try Task.checkCancellation()
                    sources.append(try await api.summary(id: id))
                }
                let overview = podcast.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = XPostDraft(title: podcast.title,
                    summary: overview.flatMap { $0.isEmpty ? nil : $0 } ?? sources.map(\.summary).joined(separator: " "),
                    sources: sources)
            } else if let summary = request.summary {
                draft = XPostDraft(title: summary.title, summary: summary.summary, sources: [summary])
            } else { return }
            try Task.checkCancellation()
            openURL(draft.url) { accepted in
                if accepted { opened += 1 }
                else { error = String(localized: "Couldn't open the X composer. Please check your browser and try again.") }
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
