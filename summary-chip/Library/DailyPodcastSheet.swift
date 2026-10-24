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
    @State private var loading = true
    @State private var showsGeneration = false
    @State private var showsVersions = false
    @State private var showsDownload = false
    @State private var showsSharing = false
    @State private var showsVideoPublication = false
    @State private var generateVideoOnly = false
    @State private var error: String?
    @State private var taps = 0

    var body: some View {
        playerLayout
            .overlay {
                if loading || (player.buffering && player.podcast?.video == nil) {
                    ProgressView(loading ? "Loading podcast…" : "Loading audio…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showsGeneration) {
                DailyPodcastGenerationSheet(api: api, date: date, existing: player.podcast, videoOnly: generateVideoOnly) { podcast in
                    guard player.date == date else { return }
                    player.replace(podcast)
                    player.toggle()
                }
            }
            .sheet(isPresented: $showsVersions) {
                PodcastVersionsSheet(api: api, date: date, player: player)
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
                Button("OK", role: .cancel) { error = nil; player.error = nil }
            } message: { Text(error ?? player.error ?? "") }
            .task {
                if player.podcast == nil {
                    do {
                        if let saved = try await api.dailyPodcast(date: date), !Task.isCancelled, player.date == date {
                            player.replace(saved)
                        }
                    }
                    catch is CancellationError {} catch { self.error = error.localizedDescription }
                }
                loading = false
            }
            .sensoryFeedback(.selection, trigger: taps)
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
                if player.podcast != nil {
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
                if player.podcast != nil {
                    Spacer(minLength: 8)
                    Button {
                        guard let id = player.segment?.chipId else { return }
                        onOpenChip(id)
                    } label: { Label("Open Chip", systemImage: "doc.text.magnifyingglass") }
                    .accessibilityIdentifier("podcast-open-chip")
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

    private var podcastActions: some View {
        Menu {
            #if os(iOS)
            Button {
                guard let id = player.segment?.chipId else { return }
                taps += 1; onOpenChip(id)
            } label: { Label("Open Chip", systemImage: "doc.text.magnifyingglass") }
            #endif
            Button { taps += 1; showsSharing = true } label: {
                Label("Publish to Web", systemImage: "square.and.arrow.up")
            }.accessibilityIdentifier("podcast-publish")
            if player.podcast?.video == nil {
                Button {
                    taps += 1; generateVideoOnly = true; showsGeneration = true
                } label: { Label("Generate Video", systemImage: "film") }
                    .accessibilityIdentifier("podcast-video-generate")
            } else {
                Button { taps += 1; showsVideoPublication = true } label: {
                    Label("Publish Video", systemImage: "film")
                }
            }
            Button { taps += 1; generateVideoOnly = false; showsGeneration = true } label: {
                Label("Regenerate Podcast", systemImage: "arrow.clockwise")
            }.accessibilityIdentifier("podcast-regenerate")
            if player.podcast?.summaryId == nil {
                Divider()
                Button { taps += 1; showsVersions = true } label: {
                    Label("Manage Versions", systemImage: "square.stack")
                }.accessibilityIdentifier("podcast-versions")
            }
            Divider()
            Button { showsDownload = true } label: {
                Label("Download Podcast", systemImage: "arrow.down.to.line")
            }.accessibilityIdentifier("podcast-download")
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("podcast-more")
        .disabled(player.buffering)
    }

    @ViewBuilder
    private var content: some View {
        if let podcast = player.podcast, player.segment != nil {
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
    @State private var language: SummaryLanguage = .en
    @State private var generating = false
    @State private var includeVideo = true
    @State private var regenerateVideoOnly = false
    @State private var pendingEpisode: DailyPodcast?
    @State private var renderProgress: PodcastMotionRenderer.Progress?
    @State private var generationProgress: PodcastGenerationProgress?
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
                    Text(isLibrary ? "Search your library and choose the source chips for a new podcast chip. Podcast chips are excluded from daily generation." : "All readable summary chips from this day are selected by default, across feed filters. You can choose which to include.")
                }
                }
                Section {
                    Text("Generation uses points. Audio and video design are saved for future playback. Keep the app open while the video renders. Each version is kept until you remove it.")
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
                        .disabled(generating || loading || (pendingEpisode == nil && !regenerateVideoOnly && selected.isEmpty))
                        .accessibilityIdentifier("podcast-generation-submit")
                }
            }
            .disabled(generating)
            .overlay { generationOverlay }
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
        language = existing.flatMap { SummaryLanguage(rawValue: $0.language) }
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
        generationProgress = nil
        renderProgress = nil
        generating = true
        Task {
            do {
                let podcast: DailyPodcast
                if let pendingEpisode {
                    if pendingEpisode.video == nil {
                        podcast = try await api.composePodcastVideo(pendingEpisode, onProgress: { generationProgress = $0 })
                    } else { podcast = pendingEpisode }
                } else if regenerateVideoOnly, let existing {
                    podcast = try await api.composePodcastVideo(existing, onProgress: { generationProgress = $0 })
                } else {
                    podcast = try await api.generateDailyPodcast(date: date, language: language, regenerate: true,
                        chipIds: selected.keys.sorted(), library: isLibrary,
                        includeVideo: includeVideo, onProgress: { generationProgress = $0 })
                }
                // Preserve the paid episode if local rendering fails. Retry never regenerates audio or design.
                pendingEpisode = podcast
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
            } catch { self.error = error.localizedDescription }
            generating = false
        }
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

private struct PodcastVersionsSheet: View {
    let api: SummaryAPIClient
    let date: Date
    @Bindable var player: DailyPodcastPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [PodcastVersion] = []
    @State private var loading = true
    @State private var busy = false
    @State private var removing: DailyPodcast?
    @State private var error: String?
    @State private var successes = 0
    @State private var status: String?
    var body: some View {
        NavigationStack {
            List(versions) { version in
                VStack(alignment: .leading, spacing: 8) {
                    Text(version.podcast.title).font(.headline)
                    Text(version.podcast.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if version.isDefault { Label("Default", systemImage: "checkmark.circle.fill").font(.caption) }
                    HStack {
                        Button("Play", systemImage: "play.fill") {
                            player.replace(version.podcast); player.toggle(); dismiss()
                        }
                        if !version.isDefault {
                            Button("Set as Default") { update(version.podcast, remove: false) }
                                .font(.caption).fixedSize()
                        }
                        Spacer()
                        Button("Remove", systemImage: "trash", role: .destructive) { removing = version.podcast }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.subheadline)
                    .lineLimit(1)
                }
                .padding(.vertical, 6)
            }
            .disabled(busy)
            .overlay {
                if loading || busy {
                    ProgressView(busy ? "Updating podcasts…" : "Loading versions…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if versions.isEmpty { ContentUnavailableView("No Versions", systemImage: "waveform") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Podcast Versions")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy).accessibilityIdentifier("podcast-versions-done") } }
            .task { await reload(); loading = false }
            .confirmationDialog("Remove this podcast version?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove Version", role: .destructive) {
                    if let removing { update(removing, remove: true) }
                    removing = nil
                }
            } message: { Text("Its share links will stop working. If it is the default, another version will become the default.") }
            .alert("Couldn't Update Podcasts", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .overlay(alignment: .top) {
                if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .padding().background(.regularMaterial, in: Capsule()).padding()
                        .allowsHitTesting(false)
                }
            }
            .interactiveDismissDisabled(busy)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
    private func reload() async {
        do { versions = try await api.podcastVersions(date: date) }
        catch { self.error = error.localizedDescription }
    }
    private func update(_ podcast: DailyPodcast, remove: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if remove { try await api.removePodcast(podcast, date: date) }
                else { try await api.selectPodcast(podcast, date: date) }
                versions = try await api.podcastVersions(date: date)
                if !remove {
                    player.replace(podcast); player.toggle()
                } else if player.podcast?.key == podcast.key {
                    player.stop()
                    if let next = versions.first(where: { $0.isDefault }) { player.replace(next.podcast) }
                    else { player.podcast = nil }
                }
                successes += 1
                status = remove ? "Version removed" : "Default updated"
                Task { try? await Task.sleep(for: .seconds(2)); status = nil }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private enum PodcastVideoGenerationError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        String(localized: "Your audio was saved, but video design was unavailable. Retry Video to generate a video for this recording.")
    }
}
