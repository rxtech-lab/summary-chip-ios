import Foundation
import SummaryKit
import SwiftUI

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
    @AppStorage("podcast.generation.videoStyle") private var savedVideoStyle = PodcastVideoStyle.news.rawValue
    @State private var speakerNames: [String] = []
    @State private var showsSpeakers = false
    @State private var videoStyle: PodcastVideoStyle = .news
    @State private var showsVideoStyles = false
    @AppStorage("podcast.generation.durationSeconds") private var savedDurationSeconds = 360
    @State private var durationSeconds = 360
    @State private var showsDuration = false
    /// Languages, speaker limits and video styles come from the server.
    @State private var options: PodcastGenerationOptions?
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
                if !regenerateVideoOnly { generationSection }
                if regenerateVideoOnly {
                    Section { videoStyleRow }
                }
                Section {
                    Text("Generation uses points. Audio and video design are saved for future playback. The video is designed and then rendered in the cloud, so you can leave while it works. Each version is kept until you remove it.")
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
                        .disabled(generating || loading || options == nil || (pendingEpisode == nil && !regenerateVideoOnly && (selected.isEmpty || !speakerNamesValid)))
                        .accessibilityIdentifier("podcast-generation-submit")
                }
            }
            .disabled(generating)
            .overlay { generationOverlay }
            .sheet(isPresented: $showsSpeakers) {
                PodcastSpeakersSheet(names: $speakerNames, limits: options?.speakers)
            }
            .sheet(isPresented: $showsChips) {
                PodcastChipPicker(api: api, dayChips: isLibrary ? nil : chips, selected: $selected)
            }
            .sheet(isPresented: $showsVideoStyles) {
                PodcastVideoStyleSheet(styles: options?.videoStyles ?? [], style: $videoStyle)
            }
            .sheet(isPresented: $showsDuration) {
                if let duration = options?.duration {
                    PodcastDurationSheet(options: duration, seconds: $durationSeconds)
                }
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
            .sensoryFeedback(.selection, trigger: videoStyle)
            .sensoryFeedback(.selection, trigger: durationSeconds)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private var generationSection: some View {
        Section {
            Picker("Media", selection: $includeVideo) {
                Text("Audio + video").tag(true)
                Text("Audio only").tag(false)
            }
            .accessibilityIdentifier("podcast-generation-media")
            Picker("Language", selection: $language) {
                ForEach(options?.languages ?? [language]) { Text($0.title).tag($0) }
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
            .disabled(options.map { $0.speakers.maxCount == 0 } ?? true)
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
            if let duration = options?.duration {
                Button { showsDuration = true } label: {
                    HStack {
                        Label("Length", systemImage: "clock")
                        Spacer()
                        let preset = duration.presets.first { $0.seconds == durationSeconds }
                        Text([preset?.title, PodcastDurationSheet.time(durationSeconds)].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("podcast-generation-duration")
                .disabled(pendingEpisode != nil)
            }
            if includeVideo { videoStyleRow }
        } footer: {
            Text(existing?.summaryId != nil ? "Choose the source chips for a new version of this podcast chip. Earlier versions stay in Manage Versions." : isLibrary ? "Search your library and choose the source chips for a new podcast chip. Podcast chips are excluded from daily generation." : "All readable summary chips from this day are selected by default. Choose the candidates; important stories are ranked first, repetitive stories are skipped, and the summary follows your chosen length.")
        }
    }

    private var videoStyleRow: some View {
        Button { showsVideoStyles = true } label: {
            HStack {
                Label("Video Style", systemImage: "paintpalette")
                Spacer()
                Text(options?.videoStyle(videoStyle)?.title ?? "").foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("podcast-generation-video-style")
        .disabled(options == nil)
    }

    private var speakerNamesValid: Bool {
        guard let limits = options?.speakers else { return false }
        return speakerNames.count <= limits.maxCount
            && !speakerNames.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.utf16.count > limits.maxNameLength }
    }

    @ViewBuilder private var generationOverlay: some View {
        if generating {
            VStack(spacing: 12) {
                if let progress = renderProgress {
                    Text(progress.title).font(.headline)
                    if let fraction = progress.fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
                    else { ProgressView().progressViewStyle(.linear) }
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
                        Text("The script keeps writing on the server if you leave, then the HD video renders in the cloud. Open Background Jobs to follow both.")
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
        do {
            let options = try await api.podcastGenerationOptions()
            // Saved choices the server no longer offers fall back to its defaults.
            let saved = PodcastVideoStyle(rawValue: savedVideoStyle)
            videoStyle = options.videoStyle(saved) != nil ? saved : options.defaultVideoStyle
            if !options.languages.contains(language), let first = options.languages.first { language = first }
            if speakerNames.count > options.speakers.maxCount { speakerNames = [] }
            if let duration = options.duration {
                durationSeconds = (duration.minSeconds...duration.maxSeconds).contains(savedDurationSeconds)
                    ? savedDurationSeconds : duration.defaultSeconds
            }
            self.options = options
        } catch { self.error = error.localizedDescription }
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
            savedDurationSeconds = durationSeconds
            if let data = try? JSONEncoder().encode(speakerNames), let value = String(data: data, encoding: .utf8) {
                savedSpeakerNames = value
            }
        }
        savedVideoStyle = videoStyle.rawValue
        generationProgress = nil
        renderProgress = nil
        generating = true
        work = Task {
            do {
                var podcast: DailyPodcast
                if let pendingEpisode {
                    // A running design is followed; otherwise a new one starts. Audio is never regenerated.
                    podcast = pendingEpisode.video != nil || pendingEpisode.isDesigningVideo ? pendingEpisode : try await api.composePodcastVideo(pendingEpisode, style: videoStyle)
                } else if regenerateVideoOnly, let existing {
                    podcast = try await api.composePodcastVideo(existing, style: videoStyle)
                } else {
                    // Regenerating a library podcast adds a version to the same chip.
                    podcast = try await api.generateDailyPodcast(date: date, language: language, regenerate: true,
                        chipIds: selected.keys.sorted(), library: isLibrary,
                        includeVideo: includeVideo, videoStyle: videoStyle, summaryID: existing?.summaryId, speakerNames: speakerNames.isEmpty ? nil : speakerNames, durationSeconds: options?.duration == nil ? nil : durationSeconds, onProgress: { generationProgress = $0 })
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
