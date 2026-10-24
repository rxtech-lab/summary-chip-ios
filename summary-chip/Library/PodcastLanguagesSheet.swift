import SummaryKit
import SwiftUI

/// The languages an episode plays in. Choosing one switches the shared player at the same turn;
/// translations can be removed here, and Add Translation opens its own creation sheet.
struct PodcastLanguagesSheet: View {
    let api: SummaryAPIClient
    @Bindable var player: DailyPodcastPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var showsTranslation = false
    @State private var removing: String?
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @State private var taps = 0
    @State private var successes = 0

    private var podcast: DailyPodcast? { player.podcast }
    private var missingLanguages: [SummaryLanguage] {
        SummaryLanguage.translations.filter { !(podcast?.availableLanguages ?? []).contains($0.rawValue) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let podcast {
                    Section {
                        ForEach(podcast.availableLanguages, id: \.self) { language in
                            Button { choose(language) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(Self.title(for: language)).foregroundStyle(.primary)
                                        if language == podcast.sourceLanguage {
                                            Text("Original").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if language == podcast.language {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(language == podcast.language ? .isSelected : [])
                            .accessibilityIdentifier("podcast-language-\(language)")
                            .swipeActions {
                                if language != podcast.sourceLanguage {
                                    Button("Remove", systemImage: "trash", role: .destructive) { removing = language }
                                }
                            }
                            .contextMenu {
                                if language != podcast.sourceLanguage {
                                    Button("Remove Translation", systemImage: "trash", role: .destructive) { removing = language }
                                }
                            }
                        }
                    } footer: {
                        Text("Each language has its own voices, captions and video. Switching keeps your place in the conversation.")
                    }
                }
            }
            .disabled(busy)
            .overlay {
                if busy || player.switchingLanguage != nil {
                    ProgressView(busy ? "Removing translation…" : "Loading language…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Languages")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(busy).accessibilityIdentifier("podcast-languages-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Translation", systemImage: "plus") { taps += 1; showsTranslation = true }
                        .disabled(busy || missingLanguages.isEmpty || podcast == nil)
                        .accessibilityIdentifier("podcast-translation-add")
                }
            }
            .sheet(isPresented: $showsTranslation) {
                if let podcast {
                    PodcastTranslationSheet(api: api, podcast: podcast, languages: missingLanguages) { translated in
                        guard player.podcast?.key == translated.key else { return }
                        player.preferredLanguage = translated.language
                        player.show(translated)
                    }
                }
            }
            .confirmationDialog("Remove this translation?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove Translation", role: .destructive) {
                    if let removing { remove(removing) }
                    removing = nil
                }
            } message: { Text("Its recording, captions and video are deleted. Share links play the other languages.") }
            .alert("Couldn't Update Languages", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .interactiveDismissDisabled(busy)
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 420, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    static func title(for language: String) -> String {
        SummaryLanguage(rawValue: language)?.title ?? Locale.current.localizedString(forIdentifier: language) ?? language
    }

    private func choose(_ language: String) {
        guard language != podcast?.language else { return }
        taps += 1
        Task {
            await player.switchLanguage(to: language)
            if player.error == nil { successes += 1 }
        }
    }

    private func remove(_ language: String) {
        guard let podcast else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let original = try await api.removePodcastTranslation(podcast, language: language)
                if player.podcast?.key == original.key {
                    if player.podcast?.language == language { player.show(original) }
                    else { player.podcast?.languages = original.languages }
                }
                if player.preferredLanguage == language { player.preferredLanguage = nil }
                successes += 1
                status = String(localized: "Translation removed")
                try? await Task.sleep(for: .seconds(2))
                status = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Creates one translation: its voices, captions and (optionally) the video with translated labels.
/// Spends points; the video is then rendered on device like a new episode.
struct PodcastTranslationSheet: View {
    let api: SummaryAPIClient
    let podcast: DailyPodcast
    let languages: [SummaryLanguage]
    let onTranslated: (DailyPodcast) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var language: SummaryLanguage?
    @State private var includeVideo = true
    @State private var translating = false
    @State private var pending: DailyPodcast?
    @State private var generationProgress: PodcastGenerationProgress?
    @State private var renderProgress: PodcastMotionRenderer.Progress?
    @State private var error: String?
    @State private var successes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(languages) { Text($0.title).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("podcast-translation-language")
                    if podcast.video != nil {
                        Picker("Media", selection: $includeVideo) {
                            Text("Audio + video").tag(true)
                            Text("Audio only").tag(false)
                        }
                    }
                } footer: {
                    Text("The hosts read the same conversation in the new language, with new captions. The video keeps its scenes and translates its labels.")
                }
                Section {
                    Text("Translation uses points. The translation is saved with this version and appears in the language list.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Add Translation")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(translating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending != nil ? "Retry Video" : "Translate") { translate() }
                        .disabled(translating || language == nil)
                        .accessibilityIdentifier("podcast-translation-submit")
                }
            }
            .disabled(translating)
            .overlay { progressOverlay }
            .interactiveDismissDisabled(translating)
            .alert("Couldn't Translate Podcast", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task {
                let preferred = SummaryLanguage(languageTag: Locale.preferredLanguages.first ?? "en")
                language = languages.first { $0 == preferred } ?? languages.first
            }
            .sensoryFeedback(.selection, trigger: language)
            .sensoryFeedback(.selection, trigger: includeVideo)
            .sensoryFeedback(.impact, trigger: translating)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    @ViewBuilder private var progressOverlay: some View {
        if translating {
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
                    ProgressView(value: progress.fraction).progressViewStyle(.linear)
                    Text("Estimated progress: \(progress.percent)%").monospacedDigit()
                    if let completed = progress.completedSegments, let total = progress.totalSegments {
                        Text("\(completed) of \(total) voice segments")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    ProgressView("Translating podcast…")
                }
            }
            .frame(maxWidth: 280)
            .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
            .accessibilityIdentifier("podcast-translation-progress")
        }
    }

    private func translate() {
        guard let language else { return }
        generationProgress = nil
        renderProgress = nil
        translating = true
        Task {
            defer { translating = false }
            do {
                // Retrying only re-renders: the paid translation is already saved.
                let translated: DailyPodcast
                if let pending { translated = pending }
                else {
                    translated = try await api.translatePodcast(podcast, language: language, includeVideo: includeVideo,
                                                                onProgress: { generationProgress = $0 })
                }
                pending = translated
                if translated.video != nil {
                    renderProgress = .init(stage: .preparing, fraction: 0)
                    _ = try await PodcastMotionRenderer.render(api: api, podcast: translated) { renderProgress = $0 }
                }
                successes += 1
                onTranslated(translated)
                dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
