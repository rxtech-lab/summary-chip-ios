import AVKit
import SummaryKit
import SwiftUI

/// Rendering is an explicit device action, separate from inspecting a server job.
struct BackgroundVideoRenderSheet: View {
    let api: SummaryAPIClient
    let podcast: DailyPodcast
    @Environment(\.dismiss) private var dismiss
    @State private var progress: PodcastMotionRenderer.Progress?
    @State private var video: AVPlayer?
    @State private var error: String?
    @State private var attempt = 0
    @State private var showsDownload = false

    var body: some View {
        NavigationStack {
            Group {
                if let video { VideoPlayer(player: video) }
                else { Color.clear }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(video == nil ? "Render Video" : "Video Ready")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(video == nil ? "Cancel" : "Done") { dismiss() } }
                if video != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Save Video", systemImage: "square.and.arrow.down") { showsDownload = true }
                    }
                }
            }
            .overlay {
                if video == nil && error == nil {
                    VStack(spacing: 12) {
                        if let fraction = progress?.fraction { ProgressView(value: fraction).frame(width: 200) }
                        else { ProgressView() }
                        Text(progress?.stage == .rendering ? "Rendering video…" : progress?.stage == .encoding ? "Encoding video…" : "Preparing video…")
                        if let detail = progress?.frameDetail { Text("Frames: \(detail)").monospacedDigit() }
                        if let transfer = progress?.transfer { Text(transfer.detail).monospacedDigit() }
                        Text("Keep the app open until rendering finishes.").font(.caption)
                    }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .task(id: attempt) {
                do {
                    let url = try await PodcastMotionRenderer.render(api: api, podcast: podcast) { progress = $0 }
                    try Task.checkCancellation()
                    video = AVPlayer(url: url)
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $showsDownload) { DailyPodcastDownloadSheet(api: api, podcast: podcast, initialFormat: .video) }
            .alert("Couldn't Render Video", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Retry") { error = nil; attempt += 1 }
                Button("Cancel", role: .cancel) { dismiss() }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.success, trigger: video != nil)
            .sensoryFeedback(.error, trigger: error)
            .sensoryFeedback(.selection, trigger: showsDownload)
            .onDisappear { video?.pause() }
        }
        .frame(minWidth: 320, idealWidth: 700, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}
