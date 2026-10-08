import Foundation
import Observation
import SummaryKit

/// One LaTeX paper being edited. Typing changes `source` at once and autosaves the whole working
/// copy about a second later (`PUT`, not a version); every save is compiled for the preview. When
/// the editor closes, the edits since the last version are saved as one (`close()`). An agent's
/// edit (a 409 on save, or a newer revision while checking in) is merged under the user's own:
/// the files they changed keep their text, everything else follows the agent.
@Observable
final class PaperEditorModel {
    enum SaveState: Equatable {
        case saved
        /// Edited; the autosave is waiting for typing to stop.
        case edited
        case saving
        case failed(String)
    }

    /// A short-lived notice over the paper after something happened outside the editor.
    enum Notice: Equatable {
        case agentUpdated
        case merged
        case versionSaved(Int)
        case compiles

        var message: String {
            switch self {
            case .agentUpdated: String(localized: "Updated by your agent")
            case .merged: String(localized: "Your agent edited too — changes merged")
            case .versionSaved(let number): String(localized: "Saved as version \(number)")
            case .compiles: String(localized: "No LaTeX errors")
            }
        }

        var systemImage: String {
            switch self {
            case .agentUpdated, .merged: "arrow.triangle.2.circlepath"
            case .versionSaved, .compiles: "checkmark.circle"
            }
        }
    }

    static let autosaveDelay: Duration = .seconds(1)
    static let pollInterval: Duration = .seconds(5)

    let api: SummaryAPIClient
    let id: String
    /// The paper as the server last returned it.
    private(set) var paper: Paper?
    /// The working copy as edited here; ahead of `paper.source` until the autosave lands.
    private(set) var source: PaperSource?
    var selectedPath: String?
    private(set) var loadError: String?
    private(set) var saveState: SaveState = .saved
    private(set) var notice: Notice?

    /// The last PDF compiled, kept on screen while the next one compiles or when it fails.
    private(set) var pdf: Data?
    private(set) var pdfRevision: Int?
    private(set) var isCompiling = false
    /// Why the latest compile produced no PDF; empty when it did.
    private(set) var compileIssues: [LatexIssue] = []
    /// The compile service failed (not the LaTeX).
    private(set) var compileError: String?

    /// A past version shown read-only instead of the working copy.
    private(set) var previewSource: PaperSource?
    private(set) var previewVersion: Int?
    private(set) var previewPDF: Data?
    private(set) var previewIssues: [LatexIssue] = []
    private(set) var isCompilingPreview = false

    /// Bumped for haptics.
    private(set) var savedCount = 0
    private(set) var failedCount = 0

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var compileTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(api: SummaryAPIClient, id: String) {
        self.api = api
        self.id = id
    }

    var isOwner: Bool { paper?.isOwner ?? false }
    /// Only the owner edits, and only the working copy: a past version is read-only.
    var canEdit: Bool { isOwner && previewSource == nil && paper?.isTranslated != true }
    /// The source on screen: the previewed version, else the working copy.
    var shownSource: PaperSource? { previewSource ?? source }
    var shownPDF: Data? { previewSource == nil ? pdf : previewPDF }
    var shownIssues: [LatexIssue] { previewSource == nil ? compileIssues : previewIssues }
    var isShownCompiling: Bool { previewSource == nil ? isCompiling : isCompilingPreview }
    var hasLocalChanges: Bool { source != nil && source != paper?.source }
    /// The working copy's bibliography with its fact-checks; none while a past version is shown.
    var references: [PaperReference] { previewSource == nil ? paper?.referenceList ?? [] : [] }
    var referenceErrors: [PaperReference] { references.filter(\.isError) }
    var isCheckingReferences: Bool { references.contains { $0.status == .checking } }
    var selectedFile: PaperFile? { selectedPath.flatMap { shownSource?.file($0) } }

    // MARK: Loading

    func load() async {
        do {
            let fresh = try await api.paper(id: id)
            adopt(fresh)
            loadError = nil
            await compile()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if paper == nil { loadError = error.localizedDescription }
        }
    }

    /// Takes the server's paper as the working copy, keeping the open file when it's still there.
    private func adopt(_ fresh: Paper) {
        let layoutChanged = fresh.rendering != paper?.rendering
        if fresh.readingLanguage != paper?.readingLanguage || fresh.rendering != paper?.rendering || (fresh.revision == paper?.revision && fresh.source != paper?.source) {
            pdf = nil
            pdfRevision = nil
        }
        paper = fresh
        source = fresh.source
        if selectedPath.flatMap({ fresh.source.file($0) }) == nil { selectedPath = fresh.mainFile }
        if layoutChanged, let previewSource { preview(previewSource, version: previewVersion) }
    }

    func readingChanged(_ fresh: Paper) async {
        adopt(fresh)
        await compile()
    }

    /// Checks for edits made elsewhere (an agent, another device) while the paper is open; picks
    /// them up when nothing here is waiting to be saved.
    func refresh() async {
        guard paper != nil, !hasLocalChanges, saveTask == nil, autosaveTask == nil else { return }
        guard let fresh = try? await api.paper(id: id), let current = paper else { return }
        // Reference checks finish after the save that started them: the same revision, newer checks.
        if fresh.revision == current.revision, fresh.readingLanguage == current.readingLanguage,
           fresh.rendering == current.rendering, fresh.source == current.source, fresh.references != current.references {
            paper?.references = fresh.references
            return
        }
        guard fresh.revision > current.revision || fresh.readingLanguage != current.readingLanguage || fresh.source != current.source || fresh.rendering != current.rendering else { return }
        // Typing started while this was in flight: the next save merges instead.
        guard !hasLocalChanges, saveTask == nil else { return }
        adopt(fresh)
        show(.agentUpdated)
        await compile()
    }

    /// Checks in every few seconds while the editor is open (the task is cancelled when it closes).
    func pollForChanges() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.pollInterval) } catch { return }
            await refresh()
        }
    }

    // MARK: Editing

    /// Sets a file's text and schedules the autosave.
    func edit(_ path: String, content: String) {
        guard canEdit, var next = source, next.file(path)?.isImage != true, next.file(path)?.content != content else { return }
        next.write(path, content: content)
        change(to: next)
    }

    /// Adds a file and opens it.
    func addFile(_ path: String, content: String) {
        guard canEdit, var next = source, next.file(path) == nil else { return }
        next.write(path, content: content)
        selectedPath = path
        change(to: next, now: true)
    }

    func addFigure(kind: PaperFigureKind, path: String, caption: String, code: String, image: PaperFile?) throws {
        guard canEdit, var next = source else { throw PaperProjectError(String(localized: "This paper can't be edited.")) }
        try next.addFigure(kind: kind, path: path, caption: caption, code: code, image: image, target: selectedPath)
        selectedPath = path
        change(to: next, now: true)
    }

    /// Create sheets stay open on save failure and can retry the pending edit.
    func saveFigure() async throws {
        await flush()
        if case .failed(let message) = saveState { throw PaperProjectError(message) }
        if hasLocalChanges { throw PaperProjectError(String(localized: "The figure is still waiting to be saved. Try again.")) }
    }

    func replaceImage(_ file: PaperFile) throws {
        guard canEdit, var next = source, next.file(file.path)?.isImage == true, file.isImage else {
            throw PaperProjectError(String(localized: "This image can't be replaced."))
        }
        next.write(file)
        if let problem = PaperLimits.problem(with: next) { throw PaperProjectError(problem) }
        change(to: next, now: true)
    }

    func renameFile(_ path: String, to newPath: String) {
        guard canEdit, var next = source, next.file(newPath) == nil else { return }
        next.rename(path, to: newPath)
        if selectedPath == path { selectedPath = newPath }
        change(to: next, now: true)
    }

    func deleteFile(_ path: String) {
        guard canEdit, var next = source, path != next.mainFile else { return }
        next.delete(path)
        if selectedPath == path { selectedPath = next.mainFile }
        change(to: next, now: true)
    }

    func setMainFile(_ path: String) {
        guard canEdit, var next = source, next.file(path)?.isTeX == true else { return }
        next.mainFile = path
        change(to: next, now: true)
    }

    func updateSettings(title: String, compiler: PaperCompiler) {
        guard canEdit, var next = source else { return }
        next.title = title
        next.compiler = compiler
        change(to: next, now: true)
    }

    private func change(to next: PaperSource, now: Bool = false) {
        source = next
        saveState = .edited
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            if !now {
                do { try await Task.sleep(for: Self.autosaveDelay) } catch { return }
            }
            guard let self else { return }
            self.autosaveTask = nil
            await self.save()
        }
    }

    /// Saves the working copy now, waiting for a save already running.
    func flush() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await saveTask?.value
        if hasLocalChanges { await save() }
    }

    private func save() async {
        if let running = saveTask {
            await running.value
            // That save's response may already carry these edits.
            guard hasLocalChanges else { return }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSave()
        }
        saveTask = task
        await task.value
        saveTask = nil
    }

    private func performSave() async {
        guard let paper, let sent = source, sent != paper.source else {
            if saveState == .saving || saveState == .edited { saveState = .saved }
            return
        }
        saveState = .saving
        do {
            let saved = try await api.savePaper(id: id, source: sent, revision: paper.revision)
            settle(saved, sent: sent)
        } catch let error as SummaryAPIError where error.isPaperRevisionConflict {
            await merge(base: paper.source, sent: sent)
        } catch {
            saveState = .failed(error.localizedDescription)
            failedCount += 1
        }
    }

    /// The save landed. Keeps edits typed while it was in flight, and saves them next.
    private func settle(_ saved: Paper, sent: PaperSource) {
        let typedSince = source != sent
        paper = saved
        if !typedSince { source = saved.source }
        saveState = typedSince ? .edited : .saved
        savedCount += 1
        if typedSince { change(to: source ?? saved.source) }
        Task { await compile() }
    }

    /// Someone else saved first (usually the agent): their version with this editor's changes on top.
    private func merge(base: PaperSource, sent: PaperSource) async {
        do {
            let fresh = try await api.paper(id: id)
            var merged = fresh.source
            for file in sent.files where base.file(file.path) != file {
                merged.write(file)
            }
            for file in base.files where sent.file(file.path) == nil { merged.delete(file.path) }
            if sent.title != base.title { merged.title = sent.title }
            if sent.compiler != base.compiler { merged.compiler = sent.compiler }
            if sent.mainFile != base.mainFile, merged.file(sent.mainFile) != nil { merged.mainFile = sent.mainFile }
            paper = fresh
            source = merged
            show(.merged)
            if merged == fresh.source {
                saveState = .saved
                await compile()
                return
            }
            let saved = try await api.savePaper(id: id, source: merged, revision: fresh.revision)
            settle(saved, sent: merged)
        } catch {
            saveState = .failed(error.localizedDescription)
            failedCount += 1
        }
    }

    // MARK: Leaving

    /// The editor closed: save what's left, then save the edits since the last version as one.
    func close() async {
        await flush()
        // After the flush, `paper` is the server's latest word on whether anything is unversioned.
        guard paper?.hasUnversionedChanges == true else { return }
        _ = try? await api.commitPaper(id: id)
    }

    /// Saves the edits since the last version as a version now, without leaving.
    func saveVersion() async throws {
        await flush()
        let commit = try await api.commitPaper(id: id)
        paper = commit.paper
        if let number = commit.version { show(.versionSaved(number)) }
    }

    // MARK: Compiling

    /// Compiles the saved working copy for the preview; one at a time, catching up to the newest save.
    func compile() async {
        if let compileTask {
            await compileTask.value
            guard pdfRevision != paper?.revision else { return }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            self.isCompiling = true
            defer { self.isCompiling = false }
            while let revision = self.paper?.revision, revision != self.pdfRevision, !Task.isCancelled {
                let reading = self.paper?.readingLanguage
                let rendering = self.paper?.rendering
                do {
                    let compiled = try await self.api.paperPDF(id: self.id, language: self.paper?.isTranslated == true ? SummaryLanguage(languageTag: self.paper?.readingLanguage ?? "") : .auto)
                    guard !Task.isCancelled else { return }
                    guard self.paper?.readingLanguage == reading, self.paper?.rendering == rendering else { continue }
                    self.pdf = compiled.data
                    self.pdfRevision = compiled.revision ?? revision
                    self.compileIssues = []
                    self.compileError = nil
                } catch let error as SummaryAPIError where error.latexIssues != nil {
                    guard self.paper?.readingLanguage == reading, self.paper?.rendering == rendering else { continue }
                    self.compileIssues = error.latexIssues ?? []
                    self.compileError = nil
                    self.pdfRevision = revision
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    guard self.paper?.readingLanguage == reading, self.paper?.rendering == rendering else { continue }
                    self.compileError = error.localizedDescription
                    return
                }
            }
        }
        compileTask = task
        await task.value
        compileTask = nil
    }

    /// Compiles strictly and lists every LaTeX error; the preview recovers from errors silently.
    func check() async throws -> PaperCheck {
        await flush()
        let result = try await api.checkPaper(id: id)
        if result.ok {
            compileIssues = []
            show(.compiles)
        } else {
            compileIssues = result.errors
        }
        return result
    }

    // MARK: Versions

    /// Shows a version's source (and its PDF) in place of the working copy; nil goes back.
    func preview(_ content: PaperSource?, version: Int?) {
        previewTask?.cancel()
        previewSource = content
        previewVersion = version
        previewPDF = nil
        previewIssues = []
        if let content, selectedPath.flatMap({ content.file($0) }) == nil { selectedPath = content.mainFile }
        if content == nil, let source, selectedPath.flatMap({ source.file($0) }) == nil { selectedPath = source.mainFile }
        guard content != nil, let version else { return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            self.isCompilingPreview = true
            defer { self.isCompilingPreview = false }
            do {
                let compiled = try await self.api.paperPDF(id: self.id, version: version, language: .auto)
                guard !Task.isCancelled else { return }
                self.previewPDF = compiled.data
            } catch let error as SummaryAPIError where error.latexIssues != nil {
                self.previewIssues = error.latexIssues ?? []
            } catch {}
        }
    }

    /// A restore landed: it is the working copy now.
    func restored(_ fresh: Paper) {
        autosaveTask?.cancel()
        autosaveTask = nil
        preview(nil, version: nil)
        adopt(fresh)
        saveState = .saved
        Task { await compile() }
    }

    func delete() async throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        try await api.deletePaper(id: id)
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

extension AppEnvironment {
    /// A just-created paper's library item, added to the library so it can be pushed and listed.
    func libraryItem(forCreated paper: Paper) async -> Summary? {
        guard let summary = try? await api.summary(id: paper.id) else {
            await library.reload()
            return nil
        }
        library.insert(summary)
        return summary
    }
}
