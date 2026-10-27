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
    @State private var showsVideoPublication = false
    @State private var generateVideoOnly = false
    /// Server-side design progress of the open episode's video.
    @State private var showsJobs = false
    @State private var designProgress: PodcastGenerationProgress?
    /// A finished design held back while the audio plays, so listening isn't interrupted.
    @State private var readyVideo: DailyPodcast?
    @State private var videoUpdates = 0
    @State private var error: String?
    @State private var taps = 0

    var body: some View {
        playerLayout
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
                    player.replace(podcast)
                    player.toggle()
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
                ToolbarItem(placement: .primaryAction) {
                    Button { showsJobs = true } label: { Label("Background Jobs", systemImage: "clock.arrow.circlepath") }
                }
                if !linkedChipIDs.isEmpty {
                    ToolbarItem(placement: .primaryAction) { linkedChipsButton }
                }
                if player.podcast != nil {
                    ToolbarItem(placement: .primaryAction) { summaryButton }
                    ToolbarItem(placement: .confirmationAction) { podcastActions }
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private var macPlayerBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button("Done") { dismiss() }
                Button { showsJobs = true } label: { Label("Background Jobs", systemImage: "clock.arrow.circlepath") }
                if player.podcast != nil {
                    Spacer(minLength: 8)
                    summaryButton
                    if !linkedChipIDs.isEmpty { linkedChipsButton }
                    podcastActions
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                } else { Spacer() }
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
            Button { taps += 1; showsSharing = true } label: {
                Label("Publish to Web", systemImage: "square.and.arrow.up")
            }.accessibilityIdentifier("podcast-publish")
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
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("podcast-more")
        .disabled(player.buffering || player.switchingLanguage != nil || generatingCover)
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

    /// Waits for the server to finish designing the open episode's video, then shows it. Free: it only reads the episode.
    private func followVideoDesign() async {
        guard let podcast = player.podcast, podcast.isDesigningVideo else { designProgress = nil; return }
        designProgress = podcast.videoDesign?.progress
        do {
            let designed = try await api.waitForPodcastVideoDesign(podcast, onProgress: { designProgress = $0 })
            designProgress = nil
            guard player.podcast?.key == designed.key, player.podcast?.language == designed.language else { return }
            videoUpdates += 1
            if player.playing { readyVideo = designed } else { player.replace(designed) }
        } catch is CancellationError {
        } catch {
            designProgress = nil
            guard player.podcast?.key == podcast.key else { return }
            if case SummaryAPIError.server(_, let body) = error { player.podcast?.videoDesign?.error = body }
            self.error = error.localizedDescription
        }
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
        } else if let designProgress {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(designProgress.percent > 10 ? "Designing video… \(designProgress.percent)%" : "Designing video…")
                    .monospacedDigit()
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

struct DailyPodcastGenerationSheet: View {
    let api: SummaryAPIClient
    let date: Date
    let existing: DailyPodcast?
    var library = false
    var initialChip: Summary? = nil
    var videoOnly = false
    let onGenerated: (DailyPodcast) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("podcast.generation.language") private var savedLanguage = ""
    @AppStorage("podcast.generation.includeVideo") private var savedIncludeVideo = true
    @AppStorage("podcast.generation.speakerNames") private var savedSpeakerNames = "[]"
    @State private var speakerNames: [String] = []
    @State private var showsSpeakers = false
    @State private var language: SummaryLanguage = .en
    @State private var generating = false
    @State private var includeVideo = true
    @State private var regenerateVideoOnly = false
    @State private var pendingEpisode: DailyPodcast?
    @State private var renderProgress: PodcastMotionRenderer.Progress?
    @State private var generationProgress: PodcastGenerationProgress?
    /// The server is designing the video; the sheet may close while it continues.
    @State private var designingVideo = false
    @State private var work: Task<Void, Never>?
    @State private var loading = true
    @State private var chips: [PodcastChip] = []
    @State private var selected: [String: PodcastChip] = [:]
    @State private var showsChips = false
    @State private var error: String?
    @State private var successes = 0
    private var isLibrary: Bool { library || existing?.summaryId != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let existing {
                    Section {
                        Picker("Regenerate", selection: $regenerateVideoOnly) {
                            Text("Podcast").tag(false)
                            Text(existing.video == nil ? "Generate Video" : "Video only").tag(true)
                        }
                    }
                }
                if !regenerateVideoOnly {
                Section {
                    Picker("Media", selection: $includeVideo) {
                        Text("Audio + video").tag(true)
                        Text("Audio only").tag(false)
                    }
                    .accessibilityIdentifier("podcast-generation-media")
                    Picker("Language", selection: $language) {
                        ForEach(SummaryLanguage.translations) { Text($0.title).tag($0) }
                    }
                    Button { showsSpeakers = true } label: {
                        HStack {
                            Label("Speakers", systemImage: "person.2")
                            Spacer()
                            Text(speakerNames.isEmpty ? String(localized: "Automatic") : speakerNames.joined(separator: ", "))
                                .foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("podcast-generation-speakers")
                    Button { showsChips = true } label: {
                        HStack {
                            Label("Chips", systemImage: "square.stack")
                            Spacer()
                            Text("\(selected.count) selected").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("podcast-select-chips")
                    .disabled(loading)
                } footer: {
                    Text(existing?.summaryId != nil ? "Choose the source chips for a new version of this podcast chip. Earlier versions stay in Manage Versions." : isLibrary ? "Search your library and choose the source chips for a new podcast chip. Podcast chips are excluded from daily generation." : "All readable summary chips from this day are selected by default. Choose the candidates; important stories are ranked first, repetitive stories are skipped, and the summary stays within 6 minutes.")
                }
                }
                Section {
                    Text("Generation uses points. Audio and video design are saved for future playback. The video is designed on the server, so you can leave while it works; keep the app open while it renders on this device. Each version is kept until you remove it.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(existing != nil ? "Regenerate Podcast" : library ? "New Podcast" : "New Daily Podcast")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(generating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingEpisode != nil ? "Retry Video" : "Generate") { generate() }
                        .disabled(generating || loading || (pendingEpisode == nil && !regenerateVideoOnly && (selected.isEmpty || speakerNames.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.utf16.count > 40 })))
                        .accessibilityIdentifier("podcast-generation-submit")
                }
            }
            .disabled(generating)
            .overlay { generationOverlay }
            .sheet(isPresented: $showsSpeakers) {
                PodcastSpeakersSheet(names: $speakerNames)
            }
            .sheet(isPresented: $showsChips) {
                PodcastChipPicker(api: api, dayChips: isLibrary ? nil : chips, selected: $selected)
            }
            .interactiveDismissDisabled(generating)
            .alert("Couldn't Generate Podcast", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task { await loadChips() }
            .sensoryFeedback(.impact, trigger: generating)
            .sensoryFeedback(.selection, trigger: language)
            .sensoryFeedback(.selection, trigger: includeVideo)
            .sensoryFeedback(.selection, trigger: regenerateVideoOnly)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    @ViewBuilder private var generationOverlay: some View {
        if generating {
            VStack(spacing: 12) {
                if let progress = renderProgress {
                    Text(progress.stage == .rendering ? "Rendering video…" : progress.stage == .encoding ? "Encoding video…" : "Preparing video…").font(.headline)
                    ProgressView(value: progress.fraction ?? 0).progressViewStyle(.linear)
                    if let fraction = progress.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                    if let detail = progress.frameDetail { Text("Frames: \(detail)").font(.caption).monospacedDigit() }
                } else if let progress = generationProgress {
                    Text(progress.title).font(.headline)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text("Estimated progress: \(progress.percent)%")
                        .monospacedDigit()
                    if let completed = progress.completedSegments, let total = progress.totalSegments {
                        Text("\(completed) of \(total) voice segments")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if designingVideo {
                        Text("The script keeps writing on the server if you leave. Open Background Jobs to view logs and render when ready.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Continue in Background") { continueInBackground() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("podcast-generation-background")
                    }
                } else {
                    ProgressView("Creating your podcast…")
                }
            }
            .frame(maxWidth: 280)
            .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
            .accessibilityIdentifier("podcast-generation-progress")
        } else if loading {
            ProgressView("Loading chips…")
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func loadChips() async {
        regenerateVideoOnly = videoOnly
        includeVideo = savedIncludeVideo
        speakerNames = (try? JSONDecoder().decode([String].self, from: Data(savedSpeakerNames.utf8))) ?? []
        language = SummaryLanguage(rawValue: savedLanguage) ?? existing.flatMap { SummaryLanguage(rawValue: $0.language) }
            ?? SummaryLanguage(languageTag: Locale.preferredLanguages.first ?? "en") ?? .en
        if let initialChip {
            let chip = PodcastChip(id: initialChip.id, title: initialChip.title, source: initialChip.source)
            selected[chip.id] = chip
        }
        if isLibrary, let existing {
            do {
                for id in Set(existing.segments.map(\.chipId)).sorted() {
                    let source = try await api.summary(id: id)
                    selected[id] = PodcastChip(id: id, title: source.title, source: source.source)
                }
            } catch { self.error = error.localizedDescription }
        } else if !isLibrary {
            do {
                chips = try await api.podcastChips(date: date)
                selected = Dictionary(uniqueKeysWithValues: chips.map { ($0.id, $0) })
            } catch { self.error = error.localizedDescription }
        }
        loading = false
    }

    private func generate() {
        if pendingEpisode == nil && !regenerateVideoOnly {
            speakerNames = speakerNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            savedLanguage = language.rawValue
            savedIncludeVideo = includeVideo
            if let data = try? JSONEncoder().encode(speakerNames), let value = String(data: data, encoding: .utf8) {
                savedSpeakerNames = value
            }
        }
        generationProgress = nil
        renderProgress = nil
        generating = true
        work = Task {
            do {
                var podcast: DailyPodcast
                if let pendingEpisode {
                    // A running design is followed; otherwise a new one starts. Audio is never regenerated.
                    podcast = pendingEpisode.video != nil || pendingEpisode.isDesigningVideo ? pendingEpisode : try await api.composePodcastVideo(pendingEpisode)
                } else if regenerateVideoOnly, let existing {
                    podcast = try await api.composePodcastVideo(existing)
                } else {
                    // Regenerating a library podcast adds a version to the same chip.
                    podcast = try await api.generateDailyPodcast(date: date, language: language, regenerate: true,
                        chipIds: selected.keys.sorted(), library: isLibrary,
                        includeVideo: includeVideo, summaryID: existing?.summaryId, speakerNames: speakerNames.isEmpty ? nil : speakerNames, onProgress: { generationProgress = $0 })
                }
                // Preserve the paid episode if design or rendering fails. Retry never regenerates audio or design.
                pendingEpisode = podcast
                if podcast.isDesigningVideo {
                    designingVideo = true
                    defer { designingVideo = false }
                    generationProgress = podcast.videoDesign?.progress
                    onGenerated(podcast)
                    successes += 1
                    dismiss()
                    generating = false
                    return
                }
                if podcast.video != nil {
                    renderProgress = .init(stage: .preparing, fraction: 0)
                    _ = try await PodcastMotionRenderer.render(api: api, podcast: podcast) { renderProgress = $0 }
                } else if includeVideo || regenerateVideoOnly {
                    onGenerated(podcast)
                    throw PodcastVideoGenerationError.unavailable
                }
                successes += 1
                onGenerated(podcast)
                dismiss()
            } catch is CancellationError {
            } catch {
                // A failed design shows Retry Video, which starts a new one.
                if pendingEpisode?.videoDesign?.error == nil, case SummaryAPIError.server(_, let body) = error, body.code.hasPrefix("PODCAST_VIDEO") {
                    pendingEpisode?.videoDesign?.error = body
                }
                self.error = error.localizedDescription
            }
            generating = false
        }
    }

    /// Closes the sheet while the server keeps designing; the podcast sheet picks up the video when it's ready.
    private func continueInBackground() {
        guard let pendingEpisode else { return }
        work?.cancel()
        work = nil
        generating = false
        designingVideo = false
        successes += 1
        onGenerated(pendingEpisode)
        dismiss()
    }
}

private struct PodcastChipPicker: View {
    let api: SummaryAPIClient
    let dayChips: [PodcastChip]?
    @Binding var selected: [String: PodcastChip]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var source: SummaryOrigin?
    @State private var results: [PodcastChip] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var taps = 0
    private var query: SummaryListQuery { .init(q: search, source: source, kind: .summary, limit: 50) }
    private var visible: [PodcastChip] {
        guard let dayChips else { return results }
        return dayChips.filter { (source == nil || $0.source == source) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Source", selection: $source) {
                        Text("All Sources").tag(SummaryOrigin?.none)
                        ForEach(SummaryOrigin.known) { Text($0.title).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("podcast-source-filter")
                    if dayChips != nil {
                        Button("Select All") {
                            for chip in visible { selected[chip.id] = chip }; taps += 1
                        }
                    }
                    Button("Clear Selection") { selected.removeAll(); taps += 1 }
                }
                Section("\(selected.count) selected") {
                    if visible.isEmpty && !loading { ContentUnavailableView.search(text: search) }
                    ForEach(visible) { chip in
                        Button {
                            if selected[chip.id] != nil { selected.removeValue(forKey: chip.id) }
                            else { selected[chip.id] = chip }
                            taps += 1
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chip.title).foregroundStyle(.primary)
                                    Text(chip.source.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected[chip.id] != nil ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected[chip.id] != nil ? Color.accentColor : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected[chip.id] != nil ? .isSelected : [])
                    }
                    if cursor != nil {
                        Button("Load More") { Task { await load(more: true) } }.disabled(loading)
                    }
                }
            }
            .overlay {
                if loading { ProgressView("Loading chips…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .navigationTitle("Choose Chips")
            .summaryInlineNavigationTitle()
            .searchable(text: $search, prompt: "Search chips")
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("podcast-chip-picker-done") }
            }
            .task(id: query) {
                guard dayChips == nil else { return }
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
                catch { return }
                await load(more: false)
            }
            .alert("Couldn't Load Chips", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.selection, trigger: taps)
        }
        .frame(minWidth: 320, idealWidth: 520, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
    private func load(more: Bool) async {
        var request = query
        if more { request.cursor = cursor }
        loading = true
        defer { loading = false }
        do {
            let page = try await api.listSummaries(request)
            try Task.checkCancellation()
            guard query.q == request.q, query.source == request.source else { return }
            let chips = page.items.filter { !$0.isExpired || $0.isOwner }.map { PodcastChip(id: $0.id, title: $0.title, source: $0.source) }
            results = more ? results + chips : chips
            cursor = page.nextCursor
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private enum PodcastVideoGenerationError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        String(localized: "Your audio was saved, but video design was unavailable. Retry Video to generate a video for this recording.")
    }
}

/// Dedicated host configuration; the generation sheet persists it when generation starts.
private struct PodcastSpeakersSheet: View {
    @Binding var names: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Speakers", selection: Binding(get: { names.count }, set: { count in
                        names = (0..<count).map { $0 < names.count ? names[$0] : "" }
                    })) {
                        Text("Automatic").tag(0)
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }
                    ForEach(names.indices, id: \.self) { index in
                        TextField("Speaker \(index + 1)", text: $names[index])
                            .accessibilityIdentifier("podcast-speaker-name-\(index)")
                    }
                } footer: {
                    Text("Choose Automatic to let the podcast choose its hosts, or enter a name for each speaker (up to 40 characters). Available voices may limit the number of speakers. These settings are saved on this device when you generate.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Speakers")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.utf16.count > 40 })
                }
            }
            .sensoryFeedback(.selection, trigger: names.count)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}
