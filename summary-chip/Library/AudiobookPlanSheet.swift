import SummaryKit
import SwiftUI

/// Plan mode for a book: a chat with the director. The latest plan sits at the end of the transcript; its speakers,
/// video theme and chapters open their own editors. Nothing is recorded until the plan is confirmed.
struct AudiobookPlanSheet: View {
    let api: SummaryAPIClient
    let options: AudiobookOptions
    let onConfirm: (AudiobookPlan, [Int]) -> Void
    let onSave: (AudiobookPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plan: AudiobookPlan
    @State private var message = ""
    @State private var pendingMessage: String?
    @State private var drawingFrames = false
    @State private var saving = false
    @State private var editingChapter: ChapterChoice?
    @State private var showsSpeakers = false
    @State private var showsMusic = false
    @State private var showsThemes = false
    @State private var theme: PodcastVideoStyle
    @State private var confirming = false
    @State private var showsChapterSelection = false
    @State private var selectedChapters: Set<Int> = []
    @State private var error: String?
    @State private var sends = 0
    @State private var taps = 0

    private struct ChapterChoice: Identifiable { let id: Int }
    private var busy: Bool { pendingMessage != nil || drawingFrames || saving }
    private var language: SummaryLanguage { SummaryLanguage(rawValue: plan.language) ?? .en }

    init(api: SummaryAPIClient, initial: AudiobookPlan, options: AudiobookOptions, onConfirm: @escaping (AudiobookPlan, [Int]) -> Void, onSave: @escaping (AudiobookPlan) -> Void) {
        self.api = api; self.options = options; self.onConfirm = onConfirm; self.onSave = onSave
        _plan = State(initialValue: initial)
        _theme = State(initialValue: initial.plan.videoTheme)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        PlanChatBubble(role: .assistant, text: String(localized: "Here's a plan for the book, with its chapters, speakers, music and scenes. Ask me to change anything, or tap a part to edit it yourself."))
                        ForEach(plan.messages) { PlanChatBubble(role: $0.role, text: $0.text) }
                        if let pendingMessage {
                            PlanChatBubble(role: .user, text: pendingMessage)
                            PlanWorkingBubble(text: String(localized: "Revising the plan…"))
                        }
                        card.id("plan")
                    }
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
#if !os(visionOS)
                .scrollDismissesKeyboard(.interactively)
#endif
                .onChange(of: plan.revision) { withAnimation { proxy.scrollTo("plan", anchor: .top) } }
                .onChange(of: pendingMessage) { if pendingMessage != nil { withAnimation { proxy.scrollTo("plan", anchor: .top) } } }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Audiobook Plan")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(pendingMessage != nil || saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select Chapters") { selectedChapters = Set(plan.plan.chapters.indices); showsChapterSelection = true }
                        .disabled(busy)
                        .accessibilityIdentifier("audiobook-plan-confirm")
                }
            }
            .overlay {
                if saving {
                    ProgressView("Saving plan…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showsChapterSelection) {
                NavigationStack {
                    List {
                        Section {
                            HStack {
                                Button("Select All") {
                                    selectedChapters = Set(plan.plan.chapters.indices)
                                }
                                .disabled(selectedChapters.count == plan.plan.chapters.count)
                                .accessibilityIdentifier("audiobook-chapters-select-all")
                                Spacer()
                                Button("Deselect All") { selectedChapters.removeAll() }
                                    .disabled(selectedChapters.isEmpty)
                                    .accessibilityIdentifier("audiobook-chapters-deselect-all")
                            }
                            .buttonStyle(.borderless)
                        }
                        Section {
                            ForEach(plan.plan.chapters.indices, id: \.self) { index in
                                Toggle(isOn: Binding(get: { selectedChapters.contains(index) }, set: { value in
                                    if value { selectedChapters.insert(index) } else { selectedChapters.remove(index) }
                                })) { Text("\(index + 1). \(plan.plan.chapters[index].title)") }
                            }
                        } footer: {
                            Text("Each selection is saved as a separate recording. Reopen this plan from the library to generate more chapters.")
                        }
                    }
                    .navigationTitle("Generate Chapters")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsChapterSelection = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Generate") { showsChapterSelection = false; confirmGeneration() }
                                .disabled(selectedChapters.isEmpty)
                        }
                    }
                    .sensoryFeedback(.selection, trigger: selectedChapters)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 320, idealWidth: 520, minHeight: 480, maxHeight: .infinity)
                .presentationSizing(.page.fitted(horizontal: true, vertical: false))
                .presentationDetents([.large])
            }
            .sheet(item: $editingChapter) { choice in
                AudiobookChapterSheet(plan: plan, index: choice.id) { save($0) }
            }
            .sheet(isPresented: $showsSpeakers) {
                AudiobookSpeakersSheet(api: api, options: options, language: language, allowsAutomatic: false, speakers: plan.plan.speakers) { speakers in
                    var document = plan.plan
                    document.speakers = speakers
                    if document != plan.plan { save(document) }
                }
            }
            .sheet(isPresented: $showsThemes, onDismiss: {
                guard theme != plan.plan.videoTheme else { return }
                var document = plan.plan
                document.videoTheme = theme
                save(document)
            }) {
                PodcastVideoStyleSheet(styles: options.themes, style: $theme)
            }
            .sheet(isPresented: $showsMusic) {
                AudiobookMusicSheet(plan: plan.plan)
            }
#if !os(macOS)
            .confirmationDialog("Generate this audiobook?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Use This Plan", action: confirmGeneration)
                Button("Keep Reviewing", role: .cancel) {}
            } message: {
                Text("About \(plan.estimate.points) points, charged when the book is saved. It's made on the server and you can leave while it works.")
            }
#endif
            .alert("Couldn't Update Plan", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task { drawFramesIfNeeded() }
            .sensoryFeedback(.impact, trigger: sends)
            .sensoryFeedback(.success, trigger: plan.revision)
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.error, trigger: error)
        }
        .interactiveDismissDisabled(pendingMessage != nil || saving)
        .frame(minWidth: 520, idealWidth: 700, minHeight: 600, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("PLAN").font(.caption2.weight(.bold)).tracking(0.8)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.tint.opacity(0.18)))
                    .foregroundStyle(.tint)
                if plan.revision > 0 { Text("Revision \(plan.revision)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(plan.plan.chapters.count) chapters").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.plan.title).font(.title3.weight(.bold))
                Text(plan.plan.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("About \(Duration.seconds(plan.estimate.seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) · about \(plan.estimate.points) points")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            row("Speakers", systemImage: "person.2", value: plan.plan.speakers.map(\.name).joined(separator: ", "), id: "audiobook-plan-speakers") { showsSpeakers = true }
            row("Music", systemImage: "music.note.list", value: String(localized: "\(plan.plan.musicCues.count) pieces"), id: "audiobook-plan-music") { showsMusic = true }
            if plan.includeVideo {
                row("Video Theme", systemImage: "paintpalette", value: options.theme(plan.plan.videoTheme)?.title ?? "", id: "audiobook-plan-theme") { showsThemes = true }
            }
            framesStatus
            Divider()
            ForEach(plan.plan.chapters.indices, id: \.self) { index in
                Button { taps += 1; editingChapter = ChapterChoice(id: index) } label: { chapterRow(index) }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityHint("Edit this chapter")
                    .accessibilityIdentifier("audiobook-plan-chapter-\(index)")
                if index < plan.plan.chapters.count - 1 { Divider() }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audiobook-plan-card")
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, value: String, id: String, action: @escaping () -> Void) -> some View {
        Button { taps += 1; action() } label: {
            HStack(spacing: 10) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 12)
                Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private var framesStatus: some View {
        if drawingFrames {
            Label { Text("Drawing scenes…") } icon: { ProgressView().controlSize(.small) }
                .font(.callout).foregroundStyle(.secondary)
        } else if plan.missingFrameCount > 0 {
            Button(action: drawFrames) { Label("Draw \(plan.missingFrameCount) Scenes", systemImage: "photo.badge.plus") }
                .buttonStyle(.bordered)
                .disabled(busy)
                .accessibilityIdentifier("audiobook-plan-draw-frames")
        }
    }

    private func chapterRow(_ index: Int) -> some View {
        let chapter = plan.plan.chapters[index]
        return HStack(alignment: .top, spacing: 12) {
            if plan.includeVideo {
                PlanFrameImage(url: plan.frame(chapter: index, scene: 0), storyboard: !chapter.scenes.isEmpty, drawing: drawingFrames)
                    .frame(width: 128, height: 72)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(index + 1)").font(.caption2.weight(.bold)).monospacedDigit()
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(.quaternary))
                    Text(chapter.title).font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                Text(chapter.synopsis).font(.callout).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                Label(chapter.music.compactMap { id in plan.plan.musicCues.first { $0.id == id }?.title }.joined(separator: " → "), systemImage: "music.note")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask to change chapters, speakers, music or scenes…", text: $message, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .onSubmit(send)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                .accessibilityIdentifier("audiobook-plan-message")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("audiobook-plan-send")
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !busy && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.utf16.count <= 2000
    }

    private func send() {
        guard canSend else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        message = ""
        pendingMessage = text
        sends += 1
        Task {
            do { apply(try await api.refineAudiobookPlan(plan, message: text)) }
            catch {
                message = text
                self.error = error.localizedDescription
            }
            pendingMessage = nil
            drawFramesIfNeeded()
        }
    }

    private func save(_ document: AudiobookPlan.Document) {
        saving = true
        Task {
            do { apply(try await api.reviseAudiobookPlan(plan, document: document)) }
            catch {
                theme = plan.plan.videoTheme
                self.error = error.localizedDescription
            }
            saving = false
            drawFramesIfNeeded()
        }
    }

    private func apply(_ updated: AudiobookPlan) {
        plan = updated
        theme = updated.plan.videoTheme
        onSave(updated)
    }

    private func drawFramesIfNeeded() {
        if plan.missingFrameCount > 0 { drawFrames() }
    }

    private func drawFrames() {
        guard !busy, plan.missingFrameCount > 0 else { return }
        drawingFrames = true
        Task {
            do { apply(try await api.drawAudiobookPlanFrames(plan)) }
            catch { self.error = error.localizedDescription }
            drawingFrames = false
        }
    }

    private func requestGeneration() {
        guard !busy else { return }
        taps += 1
#if os(macOS)
        confirmGeneration()
#else
        confirming = true
#endif
    }

    private func confirmGeneration() {
        onSave(plan)
        onConfirm(plan, selectedChapters.sorted())
        dismiss()
    }
}

/// The soundtrack: every piece and the chapters it plays in. Reused pieces are what make a theme return.
private struct AudiobookMusicSheet: View {
    let plan: AudiobookPlan.Document
    @Environment(\.dismiss) private var dismiss

    private func chapters(using cue: AudiobookPlan.MusicCue) -> [Int] {
        plan.chapters.indices.filter { plan.chapters[$0].music.contains(cue.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(plan.musicCues) { cue in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cue.title).font(.headline)
                            Text(cue.prompt).font(.callout).foregroundStyle(.secondary)
                            let used = chapters(using: cue)
                            if !used.isEmpty {
                                Text("Chapters \(used.map { String($0 + 1) }.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("The music changes when the content does, and a piece returns when its feeling does. Ask in the chat to change it.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Music")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 360, idealWidth: 480, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}

/// Edits one chapter: its title, synopsis, music and scenes.
private struct AudiobookChapterSheet: View {
    let plan: AudiobookPlan
    let index: Int
    let onSave: (AudiobookPlan.Document) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chapter: AudiobookPlan.Chapter
    @State private var deleting = false
    @State private var taps = 0

    init(plan: AudiobookPlan, index: Int, onSave: @escaping (AudiobookPlan.Document) -> Void) {
        self.plan = plan; self.index = index; self.onSave = onSave
        _chapter = State(initialValue: plan.plan.chapters[index])
    }

    private var original: AudiobookPlan.Chapter { plan.plan.chapters[index] }
    private var valid: Bool {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let synopsis = chapter.synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.utf16.count <= 120 && !synopsis.isEmpty && synopsis.utf16.count <= 1000 && !chapter.music.isEmpty
            && chapter.scenes.allSatisfy { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.prompt.utf16.count <= 800 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Chapter") {
                    TextField("Title", text: $chapter.title).accessibilityIdentifier("audiobook-chapter-title")
                    TextField("Synopsis", text: $chapter.synopsis, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("audiobook-chapter-synopsis")
                }
                Section {
                    ForEach(plan.plan.musicCues) { cue in
                        Button {
                            taps += 1
                            if let at = chapter.music.firstIndex(of: cue.id) { chapter.music.remove(at: at) } else { chapter.music.append(cue.id) }
                        } label: {
                            HStack {
                                Text(cue.title)
                                Spacer()
                                if let at = chapter.music.firstIndex(of: cue.id) {
                                    Text("\(at + 1)").font(.caption.weight(.bold)).monospacedDigit()
                                        .frame(minWidth: 20, minHeight: 20).background(Circle().fill(.tint.opacity(0.18))).foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("Music") } footer: {
                    Text("Pieces play in the numbered order, changing as the content does. Tap to add or remove.")
                }
                if plan.includeVideo {
                    Section {
                        ForEach(chapter.scenes.indices, id: \.self) { scene in
                            VStack(alignment: .leading, spacing: 8) {
                                PlanFrameImage(url: chapter.scenes[scene].prompt == original.scenes[safe: scene]?.prompt ? plan.frame(chapter: index, scene: scene) : nil, storyboard: true, drawing: false)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                TextField("What the image shows", text: $chapter.scenes[scene].prompt, axis: .vertical).lineLimit(2...6)
                                    .accessibilityIdentifier("audiobook-scene-\(scene)")
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { chapter.scenes.remove(atOffsets: $0); taps += 1 }
                        if chapter.scenes.count < 12 {
                            Button {
                                taps += 1
                                chapter.scenes.append(.init(prompt: "", motion: ["zoom-in", "pan-left", "zoom-out", "pan-right"][chapter.scenes.count % 4]))
                            } label: { Label("Add Scene", systemImage: "plus") }
                        }
                    } header: { Text("Scenes") } footer: {
                        Text("These pictures are the video. Saving redraws only the scenes you changed, and drawing uses points.")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Chapter \(index + 1)")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var document = plan.plan
                        chapter.title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        chapter.synopsis = chapter.synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
                        document.chapters[index] = chapter
                        onSave(document)
                        dismiss()
                    }
                    .disabled(!valid || chapter == original)
                    .accessibilityIdentifier("audiobook-chapter-save")
                }
            }
            .sensoryFeedback(.selection, trigger: taps)
        }
        .frame(minWidth: 420, idealWidth: 560, minHeight: 520, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
