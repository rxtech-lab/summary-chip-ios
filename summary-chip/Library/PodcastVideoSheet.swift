import SummaryKit
import SwiftUI

/// Publication is separate from creation and regeneration.
struct PodcastVideoPublicationSheet: View {
    let api: SummaryAPIClient
    let initial: DailyPodcast
    let onUpdated: (DailyPodcast) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var updated: DailyPodcast?
    @State private var confirmsRemoval = false
    @State private var operation: Task<Void, Never>?
    @State private var status: String?
    @State private var progress: Double?
    @State private var frameDetail: String?
    @State private var error: String?
    @State private var success: String?
    @State private var taps = 0
    private var podcast: DailyPodcast { updated ?? initial }

    var body: some View {
        NavigationStack {
            Form {
                if podcast.video != nil {
                    Section {
                        if podcast.video?.isPublished == true {
                            Label("Published to share links", systemImage: "checkmark.circle")
                            Button("Remove Published Video", role: .destructive) { confirmsRemoval = true }
                        } else {
                            Button("Publish Video", systemImage: "square.and.arrow.up") { publish() }
                                .accessibilityIdentifier("podcast-video-publish")
                        }
                    } footer: {
                        Text("Publishing uploads the video so this episode's web share links play it. Manage links from Publish to Web in the podcast menu.")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(status != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Publish Video")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(status != nil)
                }
            }
            .overlay { operationOverlay }
            .confirmationDialog("Remove the published video?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button("Remove Video", role: .destructive) { unpublish() }
            } message: { Text("Share links will play audio. You can publish this video again later.") }
            .alert("Couldn't Complete Video Action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .interactiveDismissDisabled(status != nil)
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.success, trigger: success)
            .sensoryFeedback(.error, trigger: error)
            .task(id: success) {
                guard success != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { success = nil }
            }
            .onDisappear { operation?.cancel() }
        }
        .frame(minWidth: 320, idealWidth: 520, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    @ViewBuilder private var operationOverlay: some View {
        if let status {
            VStack(spacing: 12) {
                if let progress { ProgressView(value: progress).frame(width: 180) }
                else { ProgressView() }
                Text(status)
                if let frameDetail {
                    Text("Frames: \(frameDetail)").monospacedDigit()
                        .accessibilityIdentifier("podcast-video-frame-progress")
                }
                if let progress {
                    Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
            }
            .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        } else if let success {
            Label(success, systemImage: "checkmark.circle.fill")
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .allowsHitTesting(false)
        }
    }

    private func run(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard status == nil else { return }
        status = label; success = nil; progress = nil; frameDetail = nil; taps += 1
        operation = Task {
            defer { status = nil; progress = nil; frameDetail = nil; operation = nil }
            do { try await action() }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func accept(_ episode: DailyPodcast) {
        updated = episode
        onUpdated(episode)
    }

    private func render() async throws -> URL {
        let url = try await PodcastMotionRenderer.render(api: api, podcast: podcast) { value in
            progress = value.fraction
            frameDetail = value.frameDetail
            switch value.stage {
            case .preparing: status = "Preparing video…"
            case .rendering: status = "Rendering video…"
            case .encoding: status = "Encoding video…"
            }
        }
        return url
    }

    private func publish() {
        run("Preparing video…") {
            guard let videoID = podcast.video?.id else { return }
            let url = try await render()
            try Task.checkCancellation()
            status = "Uploading video…"; progress = nil
            accept(try await api.publishPodcastVideo(podcast, videoId: videoID, fileURL: url))
            success = "Video published"
        }
    }

    private func unpublish() {
        run("Removing published video…") {
            accept(try await api.unpublishPodcastVideo(podcast))
            success = "Published video removed"
        }
    }
}
