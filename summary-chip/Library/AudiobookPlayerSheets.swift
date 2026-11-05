import SummaryKit
import SwiftUI

/// The book's chapters. Tapping one jumps there, and the current one is marked.
struct AudiobookChaptersSheet: View {
    @Bindable var player: DailyPodcastPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var taps = 0

    private var chapters: [DailyPodcast.Chapter] { player.podcast?.chapters ?? [] }
    private var current: Int? { player.podcast?.chapterIndex(at: player.currentTime) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chapters.indices, id: \.self) { index in
                    Button {
                        taps += 1
                        player.seek(to: chapters[index].startSeconds)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: index == current ? "speaker.wave.2.fill" : "book")
                                .foregroundStyle(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chapters[index].title).font(.body).multilineTextAlignment(.leading)
                                if let synopsis = chapters[index].synopsis {
                                    Text(synopsis).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(Duration.seconds(chapters[index].startSeconds).formatted(.time(pattern: .hourMinuteSecond)))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == current ? .isSelected : [])
                    .accessibilityIdentifier("audiobook-chapter-\(index)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Chapters")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sensoryFeedback(.selection, trigger: taps)
        }
        .frame(minWidth: 360, idealWidth: 480, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}

/// Chooses an illustration theme and starts an audiobook's video. The recording isn't touched.
struct AudiobookVideoSheet: View {
    let api: SummaryAPIClient
    let podcast: DailyPodcast
    let onStarted: (DailyPodcast) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options: AudiobookOptions?
    @State private var theme = PodcastVideoStyle(rawValue: "cinematic")
    @State private var starting = false
    @State private var showsThemes = false
    @State private var error: String?
    @State private var successes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showsThemes = true } label: {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Text(options?.theme(theme)?.title ?? "")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        } label: { Label("Video Theme", systemImage: "paintpalette").foregroundStyle(.primary) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(options == nil)
                    .accessibilityIdentifier("audiobook-video-theme")
                } footer: {
                    Text("The planned scenes are drawn in this theme and move slowly with the narration. Drawing uses points. It continues on the server if you leave, and every language gets the same scenes.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Generate Video")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(starting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate", action: start)
                        .disabled(starting || options == nil)
                        .accessibilityIdentifier("audiobook-video-generate")
                }
            }
            .overlay {
                if starting { ProgressView("Starting video…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .sheet(isPresented: $showsThemes) { PodcastVideoStyleSheet(styles: options?.themes ?? [], style: $theme) }
            .alert("Couldn't Start Video", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task {
                do {
                    let options = try await api.audiobookOptions()
                    self.options = options
                    theme = options.defaultTheme
                } catch { self.error = error.localizedDescription }
            }
            .sensoryFeedback(.selection, trigger: theme)
            .sensoryFeedback(.impact, trigger: starting)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .interactiveDismissDisabled(starting)
        .frame(minWidth: 320, idealWidth: 480, minHeight: 320, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private func start() {
        starting = true
        Task {
            defer { starting = false }
            do {
                let started = try await api.composePodcastVideo(podcast, style: theme)
                successes += 1
                onStarted(started)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// A book being made or one that stopped: follow it, retry it from where it left off, or dismiss it.
struct AudiobookJobSheet: View {
    let api: SummaryAPIClient
    let onGenerated: (DailyPodcast) -> Void
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var job: AudiobookJob
    @State private var working: String?
    @State private var dismissing = false
    @State private var error: String?
    @State private var successes = 0

    init(api: SummaryAPIClient, job: AudiobookJob, onGenerated: @escaping (DailyPodcast) -> Void, onChanged: @escaping () -> Void) {
        self.api = api; self.onGenerated = onGenerated; self.onChanged = onChanged
        _job = State(initialValue: job)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(job.title) {
                    if job.status == "failed" {
                        Label(job.error?.message ?? String(localized: "The audiobook couldn't be finished."), systemImage: "exclamationmark.triangle")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(job.stageTitle).font(.headline)
                            ProgressView(value: job.fraction).progressViewStyle(.linear)
                            Text("Estimated progress: \(job.percent)%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    if job.totalChapters > 0 {
                        LabeledContent("Chapters") { Text("\(job.completedChapters) of \(job.totalChapters)").monospacedDigit() }
                    }
                    LabeledContent("Language") { Text(PodcastLanguagesSheet.title(for: job.language)) }
                }
                if job.status == "failed" {
                    Section {
                        Button("Dismiss", role: .destructive) { dismissing = true }
                            .accessibilityIdentifier("audiobook-job-dismiss")
                    } footer: {
                        Text("Retry continues from the chapters already recorded. Nothing is charged until the book is saved.")
                    }
                } else {
                    Section {
                        Text("You can close this. The book keeps going on the server and you'll be notified when it's ready.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(job.kind == "translate" ? "Translating Audiobook" : "Making Audiobook")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(working != nil) }
                if job.status == "failed" {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Retry", action: retry).disabled(working != nil).accessibilityIdentifier("audiobook-job-retry")
                    }
                }
            }
            .overlay {
                if let working { ProgressView(working).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .confirmationDialog("Dismiss this audiobook?", isPresented: $dismissing, titleVisibility: .visible) {
                Button("Dismiss", role: .destructive, action: remove)
                Button("Cancel", role: .cancel) {}
            } message: { Text("It leaves your library's list. Chapters already recorded aren't charged.") }
            .alert("Couldn't Update Audiobook", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task(id: job.id) { await follow() }
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .interactiveDismissDisabled(working != nil)
        .frame(minWidth: 320, idealWidth: 480, minHeight: 360, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private func follow() async {
        guard job.status == "running" else { return }
        do {
            let finished = try await api.followAudiobookJob(job) { job = $0 }
            onChanged()
            if finished.status == "ready" {
                let podcast = try await api.savedPodcast(key: finished.episodeKey, day: finished.day)
                let translated = finished.language == podcast.sourceLanguage ? podcast : try await api.podcastEpisode(podcast, language: finished.language)
                successes += 1
                onGenerated(translated)
                dismiss()
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func retry() {
        working = String(localized: "Starting audiobook…")
        Task {
            defer { working = nil }
            do {
                if let planID = job.planId {
                    let plan = try await api.audiobookPlan(id: planID)
                    job = try await api.confirmAudiobookPlan(id: planID, revision: plan.revision)
                } else if let language = SummaryLanguage(rawValue: job.language) {
                    let podcast = try await api.savedPodcast(key: job.episodeKey, day: job.day)
                    job = try await api.translateAudiobook(key: podcast.key, day: job.day, language: language.rawValue, includeVideo: podcast.video != nil)
                }
                onChanged()
                await follow()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func remove() {
        working = String(localized: "Dismissing…")
        Task {
            defer { working = nil }
            do {
                try await api.dismissAudiobookJob(id: job.id)
                onChanged()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
