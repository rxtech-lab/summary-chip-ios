import Foundation
import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// Creates an audiobook from existing chips and direct PDF uploads, without creating source chips.
/// Making the book happens on the server: the sheet follows it and can be left at any point.
struct AudiobookGenerationSheet: View {
    let api: SummaryAPIClient
    let date: Date
    /// Makes a new version of this audiobook's chip.
    var existing: DailyPodcast? = nil
    var initialChip: Summary? = nil
    /// An unconfirmed plan reopened from the library: the sheet goes straight to its review.
    var resumingPlan: AudiobookPlan? = nil
    let onGenerated: (DailyPodcast) -> Void
    /// The book continues on the server after the sheet closes; the library lists it.
    var onBackground: () -> Void = {}
    /// The book is saved. Runs before it is opened, so a failure to open it can't hide it from the library.
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @AppStorage("audiobook.generation.language") private var savedLanguage = ""
    @AppStorage("audiobook.generation.includeVideo") private var savedIncludeVideo = true
    @AppStorage("audiobook.generation.theme") private var savedTheme = ""
    @AppStorage("audiobook.generation.planMode") private var planMode = true
    @State private var options: AudiobookOptions?
    @State private var language: SummaryLanguage = .en
    @State private var speakers: [AudiobookPlan.Speaker] = []
    @State private var targetSeconds: Int?
    @State private var includeVideo = true
    @State private var theme: PodcastVideoStyle = PodcastVideoStyle(rawValue: "cinematic")
    @State private var pdfSources: [AudiobookPDFSource] = []
    @State private var selected: [String: PodcastChip] = [:]
    @State private var plan: AudiobookPlan?
    @State private var showsPlan = false
    @State private var approved = false
    @State private var selectedChapters: [Int]?
    @State private var job: AudiobookJob?
    @State private var readingProgress: (completed: Int, total: Int)?
    @State private var importID: UUID?
    @State private var working: String?
    @State private var loading = true
    @State private var didLoad = false
    @State private var showsChips = false
    @State private var showsSpeakers = false
    @State private var showsThemes = false
    @State private var showsImporter = false
    @State private var error: String?
    @State private var successes = 0
    @State private var work: Task<Void, Never>?

    private var busy: Bool { working != nil || job?.status == "running" }

    var body: some View {
        NavigationStack {
            Form {
                if let plan, resumingPlan != nil {
                    resumedSection(plan)
                } else {
                    Group {
                        sourcesSection
                        voiceSection
                        outputSection
                    }
                    .disabled(plan != nil)
                    reviewSection
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(resumingPlan != nil ? "Planned Audiobook" : existing != nil ? "New Version" : "New Audiobook")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(job?.status == "failed" ? "Retry" : plan != nil ? "Review Plan" : "Generate", action: submit)
                        .disabled(busy || loading || (plan == nil && (options == nil || (selected.isEmpty && pdfSources.isEmpty))))
                        .accessibilityIdentifier("audiobook-generation-submit")
                }
            }
            .disabled(busy)
            .overlay { statusOverlay }
            .animation(.easeInOut(duration: 0.2), value: busy)
            .sheet(isPresented: $showsPlan, onDismiss: {
                // Closing without confirming keeps the draft: Review Plan reopens it, and the library lists it.
                if approved { approved = false; startConfirmed() } else if resumingPlan != nil { dismiss() }
            }) {
                if let plan, let options {
                    AudiobookPlanSheet(api: api, initial: plan, options: options, onConfirm: { self.plan = $0; selectedChapters = $1; approved = true }, onSave: { self.plan = $0 })
                }
            }
            .sheet(isPresented: $showsChips) {
                PodcastChipPicker(api: api, dayChips: nil, selected: $selected)
            }
            .sheet(isPresented: $showsSpeakers) {
                if let options {
                    AudiobookSpeakersSheet(api: api, options: options, language: language, allowsAutomatic: true, speakers: speakers) { speakers = $0 }
                }
            }
            .sheet(isPresented: $showsThemes) {
                PodcastVideoStyleSheet(styles: options?.themes ?? [], style: $theme)
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                importPDFs(result)
            }
            .interactiveDismissDisabled(busy)
            .alert("Couldn't Make Audiobook", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task {
                guard !didLoad else { return }
                didLoad = true
                await load()
            }
            .onDisappear { work?.cancel() }
            .sensoryFeedback(.impact, trigger: busy)
            .sensoryFeedback(.selection, trigger: language)
            .sensoryFeedback(.selection, trigger: includeVideo)
            .sensoryFeedback(.selection, trigger: theme)
            .sensoryFeedback(.selection, trigger: targetSeconds)
            .sensoryFeedback(.selection, trigger: planMode)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 520, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private func resumedSection(_ plan: AudiobookPlan) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.plan.title).font(.headline)
                Text(plan.plan.summary).foregroundStyle(.secondary).lineLimit(4)
                Text("\(plan.plan.chapters.count) chapters").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            sheetRow("Review Plan", systemImage: "list.bullet.clipboard", value: "", id: "audiobook-resume-plan") { showsPlan = true }
        } header: { Text("Plan") } footer: { note }
    }

    private var note: some View {
        Text("Generation uses points when the book is saved, about what the plan estimates. The book is made on the server, so you can leave while it works. Each version is kept until you remove it.")
    }

    private func sheetRow(_ title: LocalizedStringKey, systemImage: String, value: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(value).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            } label: { Label(title, systemImage: systemImage).foregroundStyle(.primary) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var sourcesSection: some View {
        Section {
            sheetRow("Chips", systemImage: "square.stack", value: String(localized: "\(selected.count) selected"), id: "audiobook-select-chips") { showsChips = true }
            Button { showsImporter = true } label: {
                Label("Upload PDF", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("audiobook-upload-pdf")
            ForEach(pdfSources) { source in
                Label(source.filename, systemImage: "doc")
                    .lineLimit(1)
            }
            if let options {
                Picker(selection: $targetSeconds) {
                    ForEach(options.lengths) { Text($0.title).tag($0.seconds) }
                } label: { Label("Length", systemImage: "clock") }
                .accessibilityIdentifier("audiobook-length")
            }
        } header: { Text("Sources") } footer: {
            Text("Chips are read from their original text, and PDFs in full. Uploaded PDFs are used directly by the audiobook without creating separate chips.")
        }
    }

    private var voiceSection: some View {
        Section("Voice") {
            Picker(selection: $language) {
                ForEach(options?.languages ?? [language]) { Text($0.title).tag($0) }
            } label: { Label("Language", systemImage: "globe") }
            sheetRow("Speakers", systemImage: "person.2", value: speakers.isEmpty ? String(localized: "Automatic") : speakers.map(\.name).joined(separator: ", "),
                     id: "audiobook-speakers") { showsSpeakers = true }
                .disabled(options == nil)
        }
    }

    @ViewBuilder private var outputSection: some View {
        if options?.video == true {
            Section {
                Picker(selection: $includeVideo) {
                    Text("Audio + video").tag(true)
                    Text("Audio only").tag(false)
                } label: { Label("Media", systemImage: "film") }
                .accessibilityIdentifier("audiobook-media")
                if includeVideo {
                    sheetRow("Video Theme", systemImage: "paintpalette", value: options?.theme(theme)?.title ?? "", id: "audiobook-theme") { showsThemes = true }
                }
            } header: { Text("Output") } footer: {
                Text("The video is made of illustrated scenes that move slowly with the narration, so it suits fiction as well as non-fiction.")
            }
        }
    }

    private var reviewSection: some View {
        Section {
            #if os(macOS)
            Toggle(isOn: planModeBinding) {
                Text("Plan Mode")
                Text("Review chapters, speakers, music and scenes after clicking Generate, and chat to change them. Nothing is recorded until you confirm. Planning uses points.")
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("audiobook-plan-mode")
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
            .accessibilityAddTraits(planMode ? .isSelected : [])
            .accessibilityIdentifier("audiobook-plan-mode")
            #endif
        } header: { Text("Review") } footer: {
            VStack(alignment: .leading, spacing: 8) {
                #if !os(macOS)
                Text("Review chapters, speakers, music and scenes after tapping Generate, and chat to change them. Nothing is recorded until you confirm. Planning uses points.")
                #endif
                note
            }
        }
    }

    /// Turning plan mode off discards the unconfirmed draft and unlocks the options.
    private var planModeBinding: Binding<Bool> {
        Binding(get: { planMode }, set: { planMode = $0; if !$0 { plan = nil } })
    }

    @ViewBuilder private var statusOverlay: some View {
        if let job, job.status == "running" {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(job.stageTitle).font(.headline)
                    ProgressView(value: job.fraction).progressViewStyle(.linear)
                    Text("Estimated progress: \(job.percent)%").monospacedDigit()
                    if job.totalChapters > 0 {
                        Text("\(job.completedChapters) of \(job.totalChapters) chapters")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text("A long book can take a while. It keeps going on the server if you leave, and you'll be notified when it's ready.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Continue in Background", action: continueInBackground)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("audiobook-background")
                }
                .frame(width: 300)
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator.opacity(0.5)))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                .padding()
                .accessibilityIdentifier("audiobook-generation-progress")
            }
            .transition(.opacity)
        } else if let working {
            VStack(spacing: 12) {
                if let progress = readingProgress, progress.total > 0 {
                    Text(working)
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .progressViewStyle(.linear)
                    Text("\(progress.completed) of \(progress.total) pages · \(progress.completed * 100 / progress.total)%")
                        .font(.caption).monospacedDigit()
                        .accessibilityIdentifier("audiobook-reading-progress")
                } else {
                    ProgressView(working)
                }
            }
            .frame(maxWidth: 320)
            .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else if loading {
            ProgressView("Loading…")
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func load() async {
        do {
            let options = try await api.audiobookOptions()
            self.options = options
            if let resumingPlan {
                plan = resumingPlan
                loading = false
                showsPlan = true
                return
            }
            language = SummaryLanguage(rawValue: savedLanguage) ?? existing.flatMap { SummaryLanguage(rawValue: $0.language) }
                ?? SummaryLanguage(languageTag: Locale.preferredLanguages.first ?? "en") ?? .en
            if !options.languages.contains(language), let first = options.languages.first { language = first }
            let saved = PodcastVideoStyle(rawValue: savedTheme)
            theme = options.theme(saved) != nil ? saved : options.defaultTheme
            includeVideo = savedIncludeVideo && options.video
            if let initialChip { selected[initialChip.id] = PodcastChip(id: initialChip.id, title: initialChip.title, source: initialChip.source) }
            if let existing {
                speakers = existing.speakers.compactMap { speaker in
                    options.voice(speaker.voice) == nil ? nil : AudiobookPlan.Speaker(name: speaker.name, voice: speaker.voice)
                }
                for id in existing.sourceChipIDs {
                    let source = try await api.summary(id: id)
                    selected[id] = PodcastChip(id: id, title: source.title, source: source.source)
                }
            }
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    /// Uploads each PDF directly as an audiobook source.
    private func importPDFs(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let failure) = result, (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
            return
        }
        work = Task {
            defer { working = nil }
            defer { readingProgress = nil; importID = nil }
            for url in urls {
                let id = UUID()
                importID = id
                readingProgress = nil
                working = String(localized: "Reading \(url.lastPathComponent)…")
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let source = try await api.uploadAudiobookPDF(fileURL: url, filename: url.lastPathComponent,
                                                           onProgress: { completed, total in
                        Task { @MainActor in
                            guard importID == id else { return }
                            readingProgress = (completed, total)
                        }
                    }, onRead: {
                        Task { @MainActor in
                            guard importID == id else { return }
                            readingProgress = nil
                            working = String(localized: "Uploading…")
                        }
                    })
                    pdfSources.append(source)
                    successes += 1
                } catch is CancellationError { return } catch {
                    self.error = error.localizedDescription
                    return
                }
            }
        }
    }

    private func submit() {
        if job?.status == "failed" || (plan != nil && !planMode) { startConfirmed(); return }
        if plan != nil { showsPlan = true; return }
        savedLanguage = language.rawValue
        savedIncludeVideo = includeVideo
        savedTheme = theme.rawValue
        working = planMode ? String(localized: "Reading the source and planning…") : String(localized: "Reading the source…")
        work = Task {
            defer { working = nil }
            do {
                let created = try await api.createAudiobook(date: date, language: language, chipIds: selected.keys.sorted(),
                    speakers: speakers.isEmpty ? nil : speakers, includeVideo: includeVideo, videoTheme: includeVideo ? theme : nil,
                    targetSeconds: targetSeconds, summaryID: existing?.summaryId, planMode: planMode, pdfSources: pdfSources)
                plan = created.plan
                successes += 1
                if let started = created.job { follow(started) } else { showsPlan = true }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    /// Starts the reviewed plan, or resumes a failed run from the chapters it finished.
    private func startConfirmed() {
        guard let plan else { return }
        working = String(localized: "Starting audiobook…")
        work = Task {
            defer { working = nil }
            do { follow(try await api.confirmAudiobookPlan(id: plan.id, revision: plan.revision, chapters: selectedChapters)) }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func follow(_ started: AudiobookJob) {
        job = started
        work = Task {
            do {
                let finished = try await api.followAudiobookJob(started) { job = $0 }
                if finished.status == "failed" {
                    error = finished.error?.message ?? String(localized: "The audiobook couldn't be finished.")
                    return
                }
                onSaved()
                let podcast = try await api.savedPodcast(key: finished.episodeKey, day: finished.day)
                successes += 1
                onGenerated(podcast)
                dismiss()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func continueInBackground() {
        work?.cancel()
        work = nil
        job = nil
        successes += 1
        onBackground()
        dismiss()
    }
}
