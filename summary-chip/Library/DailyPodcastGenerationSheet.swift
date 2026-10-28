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
    /// An unconfirmed plan reopened from the library: the sheet goes straight to its review and generates from it.
    var resumingPlan: PodcastPlan? = nil
    let onGenerated: (DailyPodcast) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("podcast.generation.language") private var savedLanguage = ""
    @AppStorage("podcast.generation.includeVideo") private var savedIncludeVideo = true
    @AppStorage("podcast.generation.speakerNames") private var savedSpeakerNames = "[]"
    @AppStorage("podcast.generation.videoStyle") private var savedVideoStyle = PodcastVideoStyle.news.rawValue
    @State private var plan: PodcastPlan?
    @State private var approvedPlan: PodcastPlan?
    @State private var showsPlan = false
    @AppStorage("podcast.generation.planMode") private var planMode = false
    @State private var preparingPlan = false
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
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(plan != nil)
                    }
                }
                if let plan, resumingPlan != nil {
                    resumedPlanSection(plan)
                } else if regenerateVideoOnly {
                    Section { videoStyleRow } footer: { generationNote }
                } else {
                    Group {
                        sourcesSection
                        voiceSection
                        outputSection
                    }
                    .disabled(plan != nil)
                    planSection
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(resumingPlan != nil ? "Planned Podcast" : existing != nil ? "Regenerate Podcast" : library ? "New Podcast" : "New Daily Podcast")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(generating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingEpisode != nil ? "Retry Video" : approvedPlan != nil ? "Retry Generation" : plan != nil ? "Review Plan" : "Generate") {
                        // Plan mode turns Generate into drafting the plan, then reviewing it; media starts after confirmation.
                        if (planMode || plan != nil) && approvedPlan == nil && pendingEpisode == nil && !regenerateVideoOnly { preparePlan() } else { generate() }
                    }
                        .disabled(generating || loading || (resumingPlan == nil && (options == nil || (pendingEpisode == nil && !regenerateVideoOnly && (selected.isEmpty || !speakerNamesValid)))))
                        .accessibilityIdentifier("podcast-generation-submit")
                }
            }
            .disabled(generating)
            .overlay { generationOverlay }
            .animation(.easeInOut(duration: 0.2), value: generating)
            .sheet(isPresented: $showsPlan, onDismiss: {
                // A plan reopened from the library returns there when closed unconfirmed; it stays listed.
                if approvedPlan != nil { generate() } else if resumingPlan != nil { dismiss() }
            }) {
                if let plan {
                    PodcastPlanSheet(api: api, initial: plan, onConfirm: { approvedPlan = $0 }, onSave: { self.plan = $0 })
                }
            }
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
            .sensoryFeedback(.selection, trigger: planMode)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 520, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private func resumedPlanSection(_ plan: PodcastPlan) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.script.title).font(.headline)
                if let summary = plan.script.summary { Text(summary).foregroundStyle(.secondary).lineLimit(4) }
                Text("\(plan.script.segments.count) lines").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            if approvedPlan == nil && pendingEpisode == nil {
                sheetRow("Review Plan", systemImage: "list.bullet.clipboard", value: "", id: "podcast-resume-plan") { showsPlan = true }
            }
        } header: {
            Text("Plan")
        } footer: {
            generationNote
        }
    }

    private var generationNote: some View {
        Text("Generation uses points. Audio and video design are saved for future playback. The video is designed and then rendered in the cloud, so you can leave while it works. Each version is kept until you remove it.")
    }

    /// A form row that opens a dedicated sheet, styled like a navigation row on every platform.
    private func sheetRow(_ title: LocalizedStringKey, systemImage: String, value: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(value).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            } label: {
                Label(title, systemImage: systemImage).foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private var planSection: some View {
        if !regenerateVideoOnly && pendingEpisode == nil {
            Section {
                #if os(macOS)
                Toggle(isOn: planModeBinding) {
                    Text("Plan Mode")
                    Text("Review and revise the script and camera storyboard after clicking Generate. Media is generated only after you confirm. Planning uses points.")
                }
                .toggleStyle(.checkbox)
                .disabled(approvedPlan != nil)
                .accessibilityIdentifier("podcast-generation-plan")
                #else
                Button { planModeBinding.wrappedValue.toggle() } label: {
                    HStack {
                        Label("Plan Mode", systemImage: "list.bullet.clipboard").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: planMode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(planMode ? Color.accentColor : Color.secondary)
                            .imageScale(.large)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(approvedPlan != nil)
                .accessibilityAddTraits(planMode ? .isSelected : [])
                .accessibilityIdentifier("podcast-generation-plan")
                #endif
            } header: {
                Text("Review")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    #if !os(macOS)
                    Text("Review and revise the script and camera storyboard after tapping Generate. Media is generated only after you confirm. Planning uses points.")
                    #endif
                    generationNote
                }
            }
        }
    }

    /// Turning plan mode off discards the unconfirmed draft and unlocks the options.
    private var planModeBinding: Binding<Bool> {
        Binding(get: { planMode }, set: { planMode = $0; if !$0 { plan = nil } })
    }

    private var sourcesSection: some View {
        Section {
            sheetRow("Chips", systemImage: "square.stack", value: String(localized: "\(selected.count) selected"), id: "podcast-select-chips") { showsChips = true }
                .disabled(loading)
            if let duration = options?.duration {
                let preset = duration.presets.first { $0.seconds == durationSeconds }
                sheetRow("Length", systemImage: "clock", value: [preset?.title, PodcastDurationSheet.time(durationSeconds)].compactMap { $0 }.joined(separator: " · "),
                         id: "podcast-generation-duration") { showsDuration = true }
                    .disabled(pendingEpisode != nil)
            }
        } header: {
            Text("Sources")
        } footer: {
            Text(existing?.summaryId != nil ? "Choose the source chips for a new version of this podcast chip. Earlier versions stay in Manage Versions." : isLibrary ? "Search your library and choose the source chips for a new podcast chip. Podcast chips are excluded from daily generation." : "All readable summary chips from this day are selected by default. Choose the candidates; important stories are ranked first, repetitive stories are skipped, and the summary follows your chosen length.")
        }
    }

    private var voiceSection: some View {
        Section("Voice") {
            Picker(selection: $language) {
                ForEach(options?.languages ?? [language]) { Text($0.title).tag($0) }
            } label: { Label("Language", systemImage: "globe") }
            sheetRow("Speakers", systemImage: "person.2", value: speakerNames.isEmpty ? String(localized: "Automatic") : speakerNames.joined(separator: ", "),
                     id: "podcast-generation-speakers") { showsSpeakers = true }
                .disabled(options.map { $0.speakers.maxCount == 0 } ?? true)
        }
    }

    private var outputSection: some View {
        Section("Output") {
            Picker(selection: $includeVideo) {
                Text("Audio + video").tag(true)
                Text("Audio only").tag(false)
            } label: { Label("Media", systemImage: "film") }
            .accessibilityIdentifier("podcast-generation-media")
            if includeVideo { videoStyleRow }
        }
    }

    private var videoStyleRow: some View {
        sheetRow("Video Style", systemImage: "paintpalette", value: options?.videoStyle(videoStyle)?.title ?? "", id: "podcast-generation-video-style") { showsVideoStyles = true }
            .disabled(options == nil)
    }

    private var speakerNamesValid: Bool {
        guard let limits = options?.speakers else { return false }
        return speakerNames.count <= limits.maxCount
            && !speakerNames.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.utf16.count > limits.maxNameLength }
    }

    @ViewBuilder private var generationOverlay: some View {
        if generating {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                generationCard
            }
            .transition(.opacity)
        } else if loading {
            ProgressView("Loading chips…")
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var generationCard: some View {
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
                    Image(systemName: preparingPlan ? "list.bullet.clipboard" : "waveform")
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(.tint)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(preparingPlan ? "Preparing script and storyboard…" : "Creating your podcast…").font(.headline)
                    if preparingPlan {
                        Text("You'll review the plan before any audio or video is made.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .frame(width: 300)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .padding()
            .accessibilityIdentifier("podcast-generation-progress")
    }

    private func loadChips() async {
        if let resumingPlan {
            // The plan carries its own sources and settings; the form isn't shown.
            // A planned video is followed while it designs; an audio-only plan must not report a missing video.
            includeVideo = false
            plan = resumingPlan
            loading = false
            showsPlan = true
            return
        }
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

    private func preparePlan() {
        if plan != nil { showsPlan = true; return }
        preparingPlan = true
        generating = true
        Task {
            do {
                plan = try await api.preparePodcastPlan(date: date, language: language, chipIds: selected.keys.sorted(),
                    library: isLibrary, includeVideo: includeVideo, videoStyle: videoStyle, summaryID: existing?.summaryId,
                    speakerNames: speakerNames.isEmpty ? nil : speakerNames, durationSeconds: options?.duration == nil ? nil : durationSeconds)
                successes += 1
                showsPlan = true
            } catch { self.error = error.localizedDescription }
            preparingPlan = false
            generating = false
        }
    }

    private func generate() {
        if pendingEpisode == nil && !regenerateVideoOnly && resumingPlan == nil {
            speakerNames = speakerNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            savedLanguage = language.rawValue
            savedIncludeVideo = includeVideo
            savedDurationSeconds = durationSeconds
            if let data = try? JSONEncoder().encode(speakerNames), let value = String(data: data, encoding: .utf8) {
                savedSpeakerNames = value
            }
        }
        if resumingPlan == nil { savedVideoStyle = videoStyle.rawValue }
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
                } else if let approvedPlan {
                    podcast = try await api.confirmPodcastPlan(approvedPlan, onProgress: { generationProgress = $0 })
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
                    if visible.isEmpty && !loading {
                        ContentUnavailableView {
                            Label(search.isEmpty ? "No Chips" : "No Results", systemImage: search.isEmpty ? "square.stack" : "magnifyingglass")
                        } description: {
                            Text(source == nil ? "Try a different search." : "Try another source or search.")
                        }
                        .listRowBackground(Color.clear)
                    }
                    ForEach(visible) { chip in
                        PodcastChipRow(chip: chip, isSelected: selected[chip.id] != nil) {
                            if selected[chip.id] != nil { selected.removeValue(forKey: chip.id) }
                            else { selected[chip.id] = chip }
                            taps += 1
                        }
                    }
                    if cursor != nil {
                        Button { Task { await load(more: true) } } label: {
                            Label("Load More", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                        }
                        .disabled(loading)
                    }
                } header: {
                    HStack {
                        Text(source.map(\.title) ?? String(localized: "All Sources"))
                        Spacer()
                        if !selected.isEmpty {
                            Text("\(selected.count) selected")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                                .textCase(nil)
                        }
                    }
                }
            }
            .overlay {
                if loading { ProgressView("Loading chips…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .animation(.snappy, value: selected.count)
            .navigationTitle("Choose Chips")
            .summaryInlineNavigationTitle()
            .searchable(text: $search, prompt: "Search chips")
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? String(localized: "Done") : String(localized: "Done (\(selected.count))")) { dismiss() }
                        .accessibilityIdentifier("podcast-chip-picker-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Source", selection: $source) {
                            Label("All Sources", systemImage: "square.stack").tag(SummaryOrigin?.none)
                            ForEach(SummaryOrigin.known) { origin in
                                Label { Text(origin.title) } icon: { origin.image }.tag(Optional(origin))
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        if dayChips != nil {
                            Button("Select All", systemImage: "checkmark.circle") {
                                for chip in visible { selected[chip.id] = chip }; taps += 1
                            }
                            .disabled(visible.isEmpty)
                        }
                        Button("Clear Selection", systemImage: "xmark.circle", role: .destructive) { selected.removeAll(); taps += 1 }
                            .disabled(selected.isEmpty)
                    } label: {
                        Label("Filter", systemImage: source == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityIdentifier("podcast-source-filter")
                }
            }
            .onChange(of: source) { taps += 1 }
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

private struct PodcastChipRow: View {
    let chip: PodcastChip
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                chip.source.image
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(chip.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(chip.source.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.08) : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum PodcastVideoGenerationError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        String(localized: "Your audio was saved, but video design was unavailable. Retry Video to generate a video for this recording.")
    }
}
