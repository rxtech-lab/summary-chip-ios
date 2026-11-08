import SummaryKit
import SwiftUI

/// The book's chapters, each with its own recording. Tapping one plays it, and the current one is marked.
/// Each can be downloaded, and one generated more than once opens its versions.
struct AudiobookChaptersSheet: View {
    let api: SummaryAPIClient
    @Bindable var player: DailyPodcastPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var taps = 0
    @State private var versionsChapter: DailyPodcast.Chapter?
    @State private var downloading: ChapterDownload?
    @State private var preparing = false
    @State private var error: String?

    private struct ChapterDownload: Identifiable {
        let podcast: DailyPodcast
        var id: String { podcast.key }
    }
    private var chapters: [DailyPodcast.Chapter] { player.book?.chapters ?? player.podcast?.chapters ?? [] }
    private var current: Int? { player.book != nil ? player.bookChapterIndex : player.podcast?.chapterIndex(at: player.currentTime) }
    private func length(_ chapter: DailyPodcast.Chapter) -> Double { player.book != nil ? chapter.endSeconds - chapter.startSeconds : chapter.startSeconds }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chapters.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Button {
                            taps += 1
                            if player.book != nil { player.playChapter(at: index, resume: player.playing) } else { player.seek(to: chapters[index].startSeconds) }
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
                                Text(Duration.seconds(length(chapters[index])).formatted(.time(pattern: .hourMinuteSecond)))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                        .accessibilityIdentifier("audiobook-chapter-\(index)")
                        if player.book != nil { actions(for: chapters[index], index: index) }
                    }
                }
            }
            .disabled(preparing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Chapters")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .overlay {
                if preparing { ProgressView("Loading chapter…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .sheet(item: $versionsChapter) { chapter in
                AudiobookChapterVersionsSheet(api: api, player: player, chapter: chapter) { dismiss() }
            }
            .sheet(item: $downloading) { DailyPodcastDownloadSheet(api: api, podcast: $0.podcast) }
            .alert("Couldn't Load Chapter", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.error, trigger: error)
        }
        .summarySheetFrame(minWidth: 360, idealWidth: 480, minHeight: 480)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private func actions(for chapter: DailyPodcast.Chapter, index: Int) -> some View {
        Menu {
            Button { download(chapter) } label: { Label("Download Chapter", systemImage: "arrow.down.circle") }
                .accessibilityIdentifier("audiobook-chapter-download-\(index)")
            if let count = chapter.versions?.count, count > 1 {
                Button { taps += 1; versionsChapter = chapter } label: { Label("\(count) Versions", systemImage: "square.stack") }
                    .accessibilityIdentifier("audiobook-chapter-versions-\(index)")
            }
        } label: {
            Label("Chapter Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("audiobook-chapter-actions-\(index)")
    }

    private func download(_ chapter: DailyPodcast.Chapter) {
        guard let key = chapter.versionId, let day = player.book?.day else { return }
        taps += 1
        preparing = true
        Task {
            defer { preparing = false }
            do { downloading = ChapterDownload(podcast: try await api.savedPodcast(key: key, day: day)) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Every recording of one chapter. Choosing one plays it from then on, without voicing or charging anything.
struct AudiobookChapterVersionsSheet: View {
    let api: SummaryAPIClient
    @Bindable var player: DailyPodcastPlayer
    let chapter: DailyPodcast.Chapter
    let onSelected: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var error: String?
    @State private var taps = 0
    @State private var successes = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chapter.versions ?? []) { version in
                        Button { select(version) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(version.title).multilineTextAlignment(.leading)
                                    Text("\(version.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Duration.seconds(version.durationSeconds).formatted(.time(pattern: .minuteSecond)))")
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if version.id == chapter.versionId { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(version.id == chapter.versionId ? .isSelected : [])
                    }
                } footer: {
                    Text("The audiobook plays the version you choose. Choosing one is free.")
                }
            }
            .disabled(choosing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Chapter Versions")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(choosing) } }
            .overlay {
                if choosing { ProgressView("Updating audiobook…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .alert("Couldn't Update Audiobook", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .interactiveDismissDisabled(choosing)
        .summarySheetFrame(minWidth: 320, idealWidth: 480, minHeight: 360)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private func select(_ version: DailyPodcast.Chapter.Version) {
        guard version.id != chapter.versionId, let current = player.book, let chapterID = chapter.bookChapterId else { return }
        taps += 1
        choosing = true
        Task {
            defer { choosing = false }
            do {
                let book = try await api.selectAudiobookChapterVersion(book: current, chapter: chapterID, version: version.id)
                player.book = book
                if let index = book.chapters?.firstIndex(where: { $0.bookChapterId == chapterID }) { player.playChapter(at: index, resume: true) }
                successes += 1
                dismiss()
                onSelected()
            } catch { self.error = error.localizedDescription }
        }
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
        .summarySheetFrame(minWidth: 320, idealWidth: 480, minHeight: 320)
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
                        Text("Retry continues from the chapters already recorded. Each chapter is charged when it's finished.")
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
            } message: { Text("It leaves your library's list. Finished chapters stay in the audiobook.") }
            .alert("Couldn't Update Audiobook", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task(id: job.id) { await follow() }
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .interactiveDismissDisabled(working != nil)
        .summarySheetFrame(minWidth: 320, idealWidth: 480, minHeight: 360)
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
