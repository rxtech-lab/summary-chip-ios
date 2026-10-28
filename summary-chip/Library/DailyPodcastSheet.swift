import AVFoundation
import Observation
import SummaryKit
import SwiftUI

struct DailyPodcastSheet: View {
    let api: SummaryAPIClient
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @Bindable var player: DailyPodcastPlayer
    let onOpenChip: (String) -> Void
    /// A library podcast's chip after its cover was redrawn, for the library card.
    var onChipUpdated: ((Summary) -> Void)? = nil
    @State private var loading = true
    @State private var generatingCover = false
    @State private var coverUpdates = 0
    @State private var showsGeneration = false
    @State private var showsVersions = false
    @State private var showsSummary = false
    @State private var showsLinkedChips = false
    @State private var pendingLinkedChipID: String?
    @State private var showsLanguages = false
    @State private var showsDownload = false
    @State private var showsSharing = false
    @State private var xSharingRequest: XSharingRequest?
    @State private var showsVideoPublication = false
    @State private var generateVideoOnly = false
    /// Server-side design progress of the open episode's video.
    @State private var showsJobs = false
    @State private var designProgress: PodcastGenerationProgress?
    /// The cloud render of a just-designed video: queued, then rendering, until it is ready to watch.
    @State private var renderState: PodcastRenderState?
    /// A finished design held back while the audio plays, so listening isn't interrupted.
    @State private var readyVideo: DailyPodcast?
    @State private var videoUpdates = 0
    @State private var error: String?
    @State private var taps = 0

    var body: some View {
        playerLayout
            .xSharing($xSharingRequest, api: api)
            .overlay {
                if generatingCover || loading || player.switchingLanguage != nil || (player.buffering && player.podcast?.video == nil) {
                    ProgressView(generatingCover ? "Generating cover…" : loading ? "Loading podcast…" : player.switchingLanguage != nil ? "Loading language…" : "Loading audio…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showsJobs) {
                BackgroundJobsSheet(api: api) { podcast in
                    player.replace(podcast)
                    showsJobs = false
                }
            }
            .sheet(isPresented: $showsGeneration) {
                DailyPodcastGenerationSheet(api: api, date: date, existing: player.podcast, videoOnly: generateVideoOnly) { podcast in
                    guard player.date == date else { return }
                    // Generation and video retries update the episode without starting playback.
                    player.replace(podcast)
                    // A regenerated library podcast redraws its chip's title and cover.
                    if let id = podcast.summaryId, let onChipUpdated {
                        Task { if let chip = try? await api.summary(id: id) { onChipUpdated(chip) } }
                    }
                }
            }
            .sheet(isPresented: $showsLinkedChips, onDismiss: {
                if let id = pendingLinkedChipID {
                    pendingLinkedChipID = nil
                    onOpenChip(id)
                }
            }) {
                PodcastLinkedChipsSheet(api: api, chipIDs: linkedChipIDs) { id in
                    pendingLinkedChipID = id
                    showsLinkedChips = false
                }
            }
            .sheet(isPresented: $showsSummary) {
                if let podcast = player.podcast {
                    PodcastSummarySheet(api: api, podcast: podcast) { updated in
                        if player.podcast?.key == updated.key { player.podcast?.summary = updated.summary }
                    }
                }
            }
            .sheet(isPresented: $showsVersions) {
                PodcastVersionsSheet(api: api, date: date, summaryID: player.podcast?.summaryId, player: player)
            }
            .sheet(isPresented: $showsLanguages) {
                PodcastLanguagesSheet(api: api, player: player)
            }
            .sheet(isPresented: $showsDownload) {
                if let podcast = player.podcast {
                    DailyPodcastDownloadSheet(api: api, podcast: podcast)
                }
            }
            .sheet(isPresented: $showsVideoPublication) {
                if let podcast = player.podcast {
                    PodcastVideoPublicationSheet(api: api, initial: podcast) { updated in
                        if player.podcast?.key == updated.key { player.podcast = updated }
                    }
                }
            }
            .sheet(isPresented: $showsSharing) {
                if let podcast = player.podcast {
                    DailyPodcastSharingSheet(api: api, podcast: podcast)
                }
            }
            .alert("Couldn't Load Podcast", isPresented: Binding(get: { error != nil || player.error != nil }, set: { if !$0 { error = nil; player.error = nil } })) {
                if player.error != nil, player.podcast != nil {
                    Button("Retry") {
                        error = nil
                        taps += 1
                        player.retryPlayback()
                    }
                    .accessibilityIdentifier("podcast-playback-retry")
                }
                Button("OK", role: .cancel) { error = nil; player.error = nil }
            } message: { Text(error ?? player.error ?? "") }
            .task {
                if player.podcast == nil {
                    do {
                        let saved = try await api.dailyPodcast(date: date)
                        try Task.checkCancellation()
                        guard player.date == date else { return }
                        if let saved {
                            player.replace(saved)
                        } else {
                            showsGeneration = true
                        }
                    }
                    catch is CancellationError {} catch { self.error = error.localizedDescription }
                }
                loading = false
            }
            .task(id: player.podcast?.key) { await player.applyPreferredLanguage() }
            .task(id: player.podcast?.videoDesign?.id) { await followVideoDesign() }
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.success, trigger: coverUpdates)
            .sensoryFeedback(.success, trigger: videoUpdates)
            .sensoryFeedback(.error, trigger: player.error)
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 760, minHeight: 480, maxHeight: .infinity)
        #else
        .frame(minWidth: 320, idealWidth: 640, minHeight: 520, maxHeight: .infinity)
        #endif
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var playerLayout: some View {
        #if os(macOS)
        // Reserve layout space for app actions so AVKit's native controls never
        // share the same hit targets or draw underneath the sheet's buttons.
        VStack(spacing: 0) {
            macPlayerBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        #else
        NavigationStack {
            content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(date.formatted(date: .abbreviated, time: .omitted))
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { podcastActions }
            }
        }
        #endif
    }

    #if os(macOS)
    private var macPlayerBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button("Done") { dismiss() }
                Spacer(minLength: 8)
                podcastActions
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .buttonStyle(MacPlayerGlassButtonStyle())
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
        }
        .environment(\.colorScheme, .dark)
        .padding(12)
    }
    #endif

    private var linkedChipIDs: [String] {
        player.podcast?.sourceChipIDs ?? []
    }

    private var summaryButton: some View {
        Button { taps += 1; showsSummary = true } label: {
            Label("Podcast Summary", systemImage: "text.alignleft")
        }
        .accessibilityIdentifier("podcast-summary")
    }

    private var linkedChipsButton: some View {
        Button { taps += 1; showsLinkedChips = true } label: {
            Label("Linked Chips", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("podcast-linked-chips")
    }

    private var podcastActions: some View {
        Menu {
            Button { taps += 1; showsJobs = true } label: {
                Label("Background Jobs", systemImage: "clock.arrow.circlepath")
            }
            if player.podcast != nil {
                summaryButton
                if !linkedChipIDs.isEmpty { linkedChipsButton }
                Divider()
                podcastEpisodeActions
                    .disabled(player.buffering || player.switchingLanguage != nil || generatingCover)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("podcast-more")
    }

    @ViewBuilder
    private var podcastEpisodeActions: some View {
        XSharingMenu(onShareToX: {
            if let podcast = player.podcast { xSharingRequest = XSharingRequest(podcast: podcast) }
        }) {
            Button { taps += 1; showsSharing = true } label: {
                Label("Publish to Web", systemImage: "square.and.arrow.up")
            }.accessibilityIdentifier("podcast-publish")
        }
        if player.podcast?.isDesigningVideo == true {
            Button {} label: { Label("Designing Video…", systemImage: "film") }
                .disabled(true)
                .accessibilityIdentifier("podcast-video-designing")
        } else if player.podcast?.video == nil {
            Button {
                taps += 1; generateVideoOnly = true; showsGeneration = true
            } label: { Label("Generate Video", systemImage: "film") }
                .accessibilityIdentifier("podcast-video-generate")
        } else {
            Button { taps += 1; showsVideoPublication = true } label: {
                Label("Publish Video", systemImage: "film")
            }
        }
        Divider()
        if let podcast = player.podcast, podcast.availableLanguages.count > 1 {
            Picker(selection: Binding(get: { podcast.language }, set: { language in
                taps += 1
                Task { await player.switchLanguage(to: language) }
            })) {
                ForEach(podcast.availableLanguages, id: \.self) { Text(PodcastLanguagesSheet.title(for: $0)).tag($0) }
            } label: {
                Label("Language", systemImage: "globe")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("podcast-language-picker")
        }
        Button { taps += 1; showsLanguages = true } label: {
            Label("Translate…", systemImage: "translate")
        }.accessibilityIdentifier("podcast-languages")
        Divider()
        Button { taps += 1; generateVideoOnly = false; showsGeneration = true } label: {
            Label("Regenerate Podcast", systemImage: "arrow.clockwise")
        }.accessibilityIdentifier("podcast-regenerate")
        if let summaryID = player.podcast?.summaryId {
            Button { taps += 1; Task { await generateCover(summaryID: summaryID) } } label: {
                Label("Generate Cover", systemImage: "photo")
            }.accessibilityIdentifier("podcast-generate-cover")
        }
        Button { taps += 1; showsVersions = true } label: {
            Label("Manage Versions", systemImage: "square.stack")
        }.accessibilityIdentifier("podcast-versions")
        Divider()
        Button { showsDownload = true } label: {
            Label("Download Podcast", systemImage: "arrow.down.to.line")
        }.accessibilityIdentifier("podcast-download")
    }

    /// Draws a new illustrated cover for the podcast's library chip.
    private func generateCover(summaryID: String) async {
        generatingCover = true
        defer { generatingCover = false }
        do {
            let chip = try await api.regenerateImage(id: summaryID, style: .illustration)
            onChipUpdated?(chip)
            coverUpdates += 1
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    /// Waits for the server to design the open episode's video, then for its cloud render (queued, then
    /// rendering), and only then shows it. Free: the design and the server's automatic render are already paid for.
    private func followVideoDesign() async {
        guard let podcast = player.podcast, podcast.isDesigningVideo else { designProgress = nil; renderState = nil; return }
        designProgress = podcast.videoDesign?.progress
        let designed: DailyPodcast
        do {
            designed = try await api.waitForPodcastVideoDesign(podcast, onProgress: { designProgress = $0 })
        } catch is CancellationError { return } catch {
            designProgress = nil
            guard player.podcast?.key == podcast.key else { return }
            if case SummaryAPIError.server(_, let body) = error { player.podcast?.videoDesign?.error = body }
            self.error = error.localizedDescription
            return
        }
        designProgress = nil
        guard isOpen(designed) else { return }
        if designed.video != nil {
            renderState = designed.video?.renders?["1080"]
            do {
                _ = try await api.waitForCloudPodcastRender(designed, onRender: { renderState = $0 })
            } catch is CancellationError { renderState = nil; return } catch {
                // The composition is saved: the player shows the render failure with Retry.
                self.error = error.localizedDescription
            }
            renderState = nil
            guard isOpen(designed) else { return }
        }
        videoUpdates += 1
        if player.playing { readyVideo = designed } else { player.replace(designed) }
    }

    private func isOpen(_ podcast: DailyPodcast) -> Bool {
        player.podcast?.key == podcast.key && player.podcast?.language == podcast.language
    }

    /// Non-blocking status while the server designs the video, or the switch to a finished one.
    @ViewBuilder
    private var videoDesignStatus: some View {
        if let readyVideo {
            Button {
                taps += 1
                self.readyVideo = nil
                player.replace(readyVideo)
            } label: { Label("Video Ready – Watch", systemImage: "play.rectangle.fill") }
                .buttonStyle(.glassProminent)
                .padding()
                .accessibilityIdentifier("podcast-video-ready")
        } else if designProgress != nil || renderState != nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Group {
                    if let designProgress {
                        Text(designProgress.percent > 10 ? "Designing video… \(designProgress.percent)%" : "Designing video…")
                    } else if renderState?.isQueued != false {
                        Text("Waiting to render video…")
                    } else {
                        Text("Rendering video in the cloud…")
                    }
                }
                .monospacedDigit()
                .contentTransition(.opacity)
            }
            .font(.subheadline)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding()
            .allowsHitTesting(false)
            .accessibilityIdentifier("podcast-video-design-status")
        }
    }

    @ViewBuilder
    private var content: some View {
        episodeContent
            .overlay(alignment: .top) { videoDesignStatus }
    }

    @ViewBuilder
    private var episodeContent: some View {
        // Not `player.segment`: it reads `currentTime`, so the sheet (and its open
        // menus) would re-render on every playback tick, closing the language submenu on macOS.
        if let podcast = player.podcast, !podcast.segments.isEmpty {
            DailyPodcastPlaybackView(api: api, podcast: podcast, player: player, onOpenChip: onOpenChip)
        } else if !loading {
            ContentUnavailableView {
                Label("Daily Podcast", systemImage: "waveform")
            } description: {
                Text("Turn this day's chips into a podcast with captions and artwork. Choose a language before generating.")
            } actions: {
                Button("Generate Podcast") { showsGeneration = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("podcast-generate")
            }
        } else {
            Color.clear
        }
    }

}

#if os(macOS)
/// Liquid Glass capsule for the dedicated podcast action bar. The padding lives
/// inside the style so the whole capsule, not just the label, is clickable (menus included).
private struct MacPlayerGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(minWidth: 34, minHeight: 34)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
#endif
