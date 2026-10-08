import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// A LaTeX paper: the source editor and its compiled PDF. iPad and Mac show them side by side and
/// the preview recompiles after each autosave; iPhone shows the editor with the PDF one tap away
/// in a sheet. Edits autosave; leaving the paper saves them as one version.
struct PaperDetailView: View {
    let environment: AppEnvironment
    let title: String
    @State private var model: PaperEditorModel
    /// The paper's saved versions; picking a past one shows its source and PDF read-only.
    @State private var versions: DocumentVersionsModel
    @State private var activeSheet: PaperSheet?
    @State private var jump: PaperLineJump?
    @State private var confirmsFileDeletion = false
    /// Downloading a PDF whose references didn't all hold up asks first.
    @State private var confirmsReferenceExport = false
    @State private var exportedPDF: TripPDFDocument?
    @State private var isPreparingPDF = false
    @State private var isChecking = false
    @State private var isLoadingItem = false
    @State private var isSavingVersion = false
    @State private var isImportingImage = false
    @State private var actionError: String?
    @State private var exportFinished = 0
    @State private var actionFailed = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(environment: AppEnvironment, paperID: String, title: String = "") {
        self.environment = environment
        self.title = title
        _model = State(initialValue: PaperEditorModel(api: environment.api, id: paperID))
        _versions = State(initialValue: DocumentVersionsModel(api: environment.api, id: paperID))
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var busyMessage: String? {
        if isImportingImage { return String(localized: "Importing image…") }
        if isPreparingPDF { return String(localized: "Preparing PDF…") }
        if isChecking { return String(localized: "Checking LaTeX…") }
        if isLoadingItem { return String(localized: "Opening…") }
        if isSavingVersion { return String(localized: "Saving version…") }
        return nil
    }

    var body: some View {
        feedback(presentations(lifecycle(versionTracking(page))))
    }

    private var page: some View {
        Group {
            if let source = model.shownSource {
                content(source)
            } else if let error = model.loadError {
                ContentUnavailableView {
                    Label("Paper unavailable", systemImage: "doc.richtext")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView("Opening paper…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.shownSource?.title ?? title)
        .summaryInlineNavigationTitle()
        .summaryHideTabBar()
        .toolbar { toolbar }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Label(notice.message, systemImage: notice.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("paper-notice")
            }
        }
        .overlay(alignment: .bottom) {
            VersionPreviewBanner(model: versions)
                .frame(maxWidth: 560)
        }
        .overlay {
            if let busyMessage { ActionStatusOverlay(busyMessage) }
        }
    }

    private func versionTracking(_ content: some View) -> some View {
        content
        .animation(.spring(duration: 0.35), value: model.notice)
        .documentVersions(versions, presentsHistory: false) { restored in
            guard let paper = restored.paper else { return }
            model.restored(paper)
            refreshLibraryItem()
        }
        .onChange(of: versions.showsHistory) { _, shows in
            guard shows else { return }
            versions.showsHistory = false
            activeSheet = .versions
        }
        .onChange(of: versions.preview) { _, preview in
            if case .paper(let source) = preview?.content {
                model.preview(source, version: preview?.info.version)
            } else {
                model.preview(nil, version: nil)
            }
        }
    }

    private func lifecycle(_ content: some View) -> some View {
        content
        .task {
            await model.load()
            if model.isOwner { await versions.reload() }
        }
        // Agent edits show up while the paper is open; the loop ends when the page closes.
        .task { await model.pollForChanges() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        // A new version appears on every agent edit and restore.
        .onChange(of: model.paper?.version) { old, new in
            guard model.isOwner, old != nil, old != new else { return }
            Task { await versions.reload() }
        }
        // Leaving the paper turns the edits since the last version into one.
        .onDisappear {
            let model = model
            let environment = environment
            Task {
                await model.close()
                if let item = try? await environment.api.summary(id: model.id) { environment.library.upsert(item) }
            }
        }
    }

    private func presentations(_ content: some View) -> some View {
        content
        .sheet(item: $activeSheet) { sheet in sheetContent(sheet) }
        .confirmationDialog(
            String(localized: "Delete \(model.selectedPath ?? "")?"),
            isPresented: $confirmsFileDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) {
                if let path = model.selectedPath { model.deleteFile(path) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is removed from the paper. Earlier versions still have it.")
        }
        .confirmationDialog(
            model.referenceErrors.count == 1
                ? String(localized: "1 reference has an error")
                : String(localized: "\(model.referenceErrors.count) references have errors"),
            isPresented: $confirmsReferenceExport,
            titleVisibility: .visible
        ) {
            Button("Download Anyway") { Task { await downloadPDF() } }
                .accessibilityIdentifier("paper-download-anyway")
            Button("Review References") { activeSheet = .references }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their links don't open, the works can't be found or aren't reliable, or they don't support what cites them. The PDF will include them as they are.")
        }
        .fileExporter(
            isPresented: Binding(get: { exportedPDF != nil }, set: { if !$0 { exportedPDF = nil } }),
            document: exportedPDF,
            contentType: .pdf,
            defaultFilename: exportedPDF?.filename
        ) { result in
            switch result {
            case .success: exportFinished += 1
            case .failure(let error):
                actionFailed += 1
                actionError = error.localizedDescription
            }
        }
        .statusAlert("Something Went Wrong", message: actionError) { actionError = nil }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ source: PaperSource) -> some View {
        if isCompact {
            editor(source)
        } else {
            PaperSplitView {
                editor(source)
            } preview: {
                PaperPreviewPane(model: model, onShowIssues: { activeSheet = .issues }, onShowReferences: { activeSheet = .references })
            }
        }
    }

    private func editor(_ source: PaperSource) -> some View {
        Group {
            if let file = model.selectedFile {
                if file.isImage {
                    PaperAssetView(file: file, api: environment.api, paperID: model.id, version: model.previewVersion)
                } else {
                    PaperSourceEditor(
                        text: Binding(get: { model.selectedFile?.content ?? "" }, set: { model.edit(file.path, content: $0) }),
                        fileID: "\(model.previewSource == nil ? "work" : "preview"):\(file.path)",
                        language: LaTeXLanguage(fileExtension: file.fileExtension),
                        isEditable: model.canEdit,
                        jump: jump,
                        issues: model.shownIssues.compactMap { issue in
                            guard issue.file == file.path, let line = issue.line else { return nil }
                            return PaperEditorIssue(line: line, message: issue.message)
                        },
                        symbols: { [model] in model.shownSource.map(LaTeXSymbols.init) ?? LaTeXSymbols() },
                        onImageDrop: importDroppedImage
                    )
                }
            } else {
                ContentUnavailableView("No File Open", systemImage: "doc.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if model.previewSource == nil, model.isOwner {
                PaperSaveStatus(state: model.saveState)
                    .padding(12)
            }
        }
        .modifier(PaperImageDropTarget(isEnabled: model.canEdit && activeSheet == nil && busyMessage == nil, onDrop: importDroppedImage))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let source = model.shownSource {
            ToolbarItem(placement: .principal) {
                fileMenu(source)
            }
            if model.canEdit {
                ToolbarItem(placement: .summaryTrailing) {
                    Button { activeSheet = .figure(.image) } label: {
                        Label("Add Image…", systemImage: "photo.badge.plus")
                    }
                    .disabled(source.files.count + 2 > PaperPath.maxFiles || busyMessage != nil)
                    .help("Add Image")
                    .accessibilityIdentifier("paper-toolbar-add-image")
                }
            }
            if isCompact {
                ToolbarItem(placement: .summaryTrailing) {
                    Button { activeSheet = .preview } label: {
                        Label("PDF", systemImage: model.shownIssues.isEmpty ? "doc.richtext" : "exclamationmark.triangle")
                    }
                    .help("Show PDF")
                    .accessibilityIdentifier("paper-show-pdf")
                }
            } else if model.isOwner {
                ToolbarItem(placement: .summaryTrailing) {
                    VersionToolbarMenu(model: versions)
                }
            }
            ToolbarItem(placement: .summaryTrailing) {
                moreMenu
            }
        }
    }

    private func fileMenu(_ source: PaperSource) -> some View {
        Menu {
            Picker("File", selection: Binding(get: { model.selectedPath ?? source.mainFile }, set: { open($0) })) {
                ForEach(source.orderedFiles) { file in
                    Label(file.path, systemImage: file.path == source.mainFile ? "star.fill" : file.systemImage)
                        .tag(file.path)
                }
            }
            .pickerStyle(.inline)
            if model.canEdit {
                Divider()
                Button { activeSheet = .newFile } label: { Label("New File…", systemImage: "doc.badge.plus") }
                    .disabled(source.files.count >= PaperPath.maxFiles)
                    .accessibilityIdentifier("paper-new-file")
                Button { activeSheet = .figure(.image) } label: { Label("Add Image…", systemImage: "photo.badge.plus") }
                    .disabled(source.files.count + 2 > PaperPath.maxFiles)
                    .accessibilityIdentifier("paper-add-image")
                Menu {
                    ForEach([PaperFigureKind.tikz, .plot]) { kind in
                        Button { activeSheet = .figure(kind) } label: { Label(kind.title, systemImage: kind.systemImage) }
                    }
                } label: { Label("Add Figure…", systemImage: "chart.xyaxis.line") }
                    .disabled(source.files.count >= PaperPath.maxFiles)
                if let file = model.selectedFile {
                    Button { activeSheet = .renameFile(file) } label: { Label("Rename \(file.name)…", systemImage: "pencil") }
                    if file.isImage {
                        Button { activeSheet = .replaceImage(file) } label: { Label("Replace Image…", systemImage: "photo.badge.arrow.down") }
                    }
                    if file.isTeX, file.path != source.mainFile {
                        Button { model.setMainFile(file.path) } label: { Label("Set as Main File", systemImage: "star") }
                    }
                    if file.path != source.mainFile {
                        Button(role: .destructive) { confirmsFileDeletion = true } label: { Label("Delete \(file.name)…", systemImage: "trash") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.selectedFile?.systemImage ?? "doc.text")
                Text(model.selectedFile?.path ?? source.mainFile)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
        }
        .menuIndicator(.hidden)
        .help("Files")
        .accessibilityIdentifier("paper-file-menu")
    }

    private var moreMenu: some View {
        Menu {
            Button { Task { await check() } } label: { Label("Check LaTeX", systemImage: "checkmark.seal") }
                .accessibilityIdentifier("paper-check")
            if !model.shownIssues.isEmpty {
                Button { activeSheet = .issues } label: { Label("Show LaTeX Errors", systemImage: "exclamationmark.triangle") }
            }
            if model.isOwner, !model.references.isEmpty {
                Button { activeSheet = .references } label: {
                    Label(model.referenceErrors.isEmpty ? String(localized: "References…") : String(localized: "References (\(model.referenceErrors.count) errors)…"),
                          systemImage: model.referenceErrors.isEmpty ? "books.vertical" : "exclamationmark.triangle")
                }
                .accessibilityIdentifier("paper-references-menu")
            }
            Button { requestDownload() } label: { Label("Download PDF", systemImage: "arrow.down.doc") }
                .accessibilityIdentifier("paper-download")
            if model.isOwner {
                Divider()
                if isCompact {
                    Button { activeSheet = .versions } label: { Label("Version History…", systemImage: "clock.arrow.circlepath") }
                        .accessibilityIdentifier("paper-versions")
                }
                if model.canEdit {
                    Button { Task { await saveVersion() } } label: { Label("Save Version Now", systemImage: "clock.badge.checkmark") }
                        .accessibilityIdentifier("paper-save-version")
                    Button { activeSheet = .settings } label: { Label("Paper Settings…", systemImage: "slider.horizontal.3") }
                        .accessibilityIdentifier("paper-settings")
                }
                Button { Task { await openItem { .share($0) } } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("paper-share")
                Divider()
                Button(role: .destructive) { Task { await openItem { .deletePaper($0) } } } label: {
                    Label("Delete Paper…", systemImage: "trash")
                }
                .accessibilityIdentifier("paper-delete")
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("paper-more")
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: PaperSheet) -> some View {
        switch sheet {
        case .preview:
            PaperPreviewSheet(model: model, onShowIssues: { activeSheet = .issues }, onShowReferences: { activeSheet = .references })
        case .references:
            PaperReferencesSheet(model: model) { reference in open(reference.file, line: reference.line) }
        case .issues:
            PaperIssuesSheet(issues: model.shownIssues) { path in open(path, line: model.shownIssues.first { $0.file == path }?.line) }
        case .newFile:
            if let source = model.source {
                PaperFileSheet(source: source) { path in model.addFile(path, content: Self.starter(for: path)) }
            }
        case .figure(let kind):
            figureSheet(kind)
        case .droppedImage(let image):
            figureSheet(.image, importedImage: image)
        case .replaceImage(let file):
            if let source = model.source {
                PaperFigureSheet(source: source, kind: .image, replacing: file, uploadImage: { path, data in
                    try await environment.api.uploadPaperImage(path: path, data: data)
                }) { _, _, _, image in
                    guard let image else { throw PaperProjectError(String(localized: "Choose an image to replace this file.")) }
                    try model.replaceImage(image)
                } onSave: {
                    try await model.saveFigure()
                }
            }
        case .renameFile(let file):
            if let source = model.source {
                PaperFileSheet(source: source, renaming: file) { path in model.renameFile(file.path, to: path) }
            }
        case .settings:
            if let source = model.source {
                PaperSettingsSheet(source: source) { title, compiler in model.updateSettings(title: title, compiler: compiler) }
            }
        case .versions:
            VersionHistorySheet(model: versions)
        case .share(let summary):
            ShareModeSheet(summary: summary, api: environment.api) { environment.library.upsert($0) }
        case .deletePaper(let summary):
            DeleteSummarySheet(api: environment.api, summary: summary) {
                environment.library.remove(id: summary.id)
                environment.likes.remove(id: summary.id)
                dismiss()
            }
        }
    }
}

extension PaperDetailView {
    // MARK: Actions

    fileprivate func feedback(_ content: some View) -> some View {
        content
        .sensoryFeedback(.selection, trigger: model.selectedPath)
        .sensoryFeedback(.selection, trigger: activeSheet)
        .sensoryFeedback(.selection, trigger: isImportingImage) { _, importing in importing }
        .sensoryFeedback(.success, trigger: exportFinished)
        .sensoryFeedback(.error, trigger: actionFailed)
        .sensoryFeedback(.error, trigger: model.failedCount)
        .sensoryFeedback(trigger: model.notice) { _, notice -> SensoryFeedback? in notice == nil ? nil : .success }
        .sensoryFeedback(.warning, trigger: model.compileIssues.count) { old, new in old == 0 && new > 0 }
        .sensoryFeedback(.warning, trigger: model.referenceErrors.count) { old, new in new > old }
        .sensoryFeedback(.warning, trigger: confirmsReferenceExport) { _, shows in shows }
    }

    @ViewBuilder
    fileprivate func figureSheet(_ kind: PaperFigureKind, importedImage: PaperImageImport? = nil) -> some View {
        if let source = model.source {
            PaperFigureSheet(source: source, kind: kind, importedImage: importedImage, uploadImage: { path, data in
                try await environment.api.uploadPaperImage(path: path, data: data)
            }) { path, caption, code, image in
                try model.addFigure(kind: kind, path: path, caption: caption, code: code, image: image)
            } onSave: {
                try await model.saveFigure()
            }
        }
    }

    fileprivate func importDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard model.canEdit, activeSheet == nil, busyMessage == nil else { return false }
        guard providers.count == 1, let provider = providers.first else {
            actionError = String(localized: "Add one image at a time.")
            actionFailed += 1
            return false
        }
        isImportingImage = true
        PaperImageImport.load(provider) { result in
            Task { @MainActor in
                defer { isImportingImage = false }
                do {
                    guard model.canEdit, activeSheet == nil, let source = model.source else { return }
                    guard source.files.count + 2 <= PaperPath.maxFiles else {
                        throw PaperProjectError(String(localized: "A paper can have at most 60 files."))
                    }
                    let image = try result.get()
                    _ = try image.stagedFile(in: source)
                    activeSheet = .droppedImage(image)
                } catch {
                    actionError = error.localizedDescription
                    actionFailed += 1
                }
            }
        }
        return true
    }

    fileprivate func open(_ path: String, line: Int? = nil) {
        model.selectedPath = path
        if let line { jump = PaperLineJump(line: line) }
    }

    /// What a new file starts with.
    fileprivate static func starter(for path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        switch (path as NSString).pathExtension.lowercased() {
        case "tex": return "\\section{\(name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized)}\n\n"
        case "bib": return "% BibTeX entries\n"
        default: return ""
        }
    }

    fileprivate func check() async {
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await model.check()
            if !result.ok { activeSheet = .issues }
        } catch {
            actionFailed += 1
            actionError = error.localizedDescription
        }
    }

    /// The PDF on screen when it's current, else a fresh compile of the saved paper.
    /// Downloads the PDF, first asking when the working copy has reference errors.
    fileprivate func requestDownload() {
        if model.previewSource == nil, !model.referenceErrors.isEmpty {
            confirmsReferenceExport = true
        } else {
            Task { await downloadPDF() }
        }
    }

    fileprivate func downloadPDF() async {
        isPreparingPDF = true
        defer { isPreparingPDF = false }
        let title = model.shownSource?.title ?? title
        do {
            let data: Data
            if let preview = versions.preview?.info.version, model.previewSource != nil {
                if let shown = model.previewPDF {
                    data = shown
                } else {
                    data = try await environment.api.paperPDF(id: model.id, version: preview).data
                }
            } else {
                await model.flush()
                if let pdf = model.pdf, model.pdfRevision == model.paper?.revision, model.compileIssues.isEmpty {
                    data = pdf
                } else {
                    data = try await environment.api.paperPDF(id: model.id).data
                }
            }
            exportedPDF = TripPDFDocument(data: data, title: title)
        } catch {
            actionFailed += 1
            actionError = (error as? SummaryAPIError)?.latexIssues.map { _ in
                String(localized: "The paper has LaTeX errors, so there's no PDF to download. Fix them and try again.")
            } ?? error.localizedDescription
        }
    }

    fileprivate func saveVersion() async {
        isSavingVersion = true
        defer { isSavingVersion = false }
        do {
            try await model.saveVersion()
            await versions.reload()
        } catch {
            actionFailed += 1
            actionError = error.localizedDescription
        }
    }

    /// The paper's library item (its sharing settings live there), then the sheet it opens.
    fileprivate func openItem(_ sheet: (Summary) -> PaperSheet) async {
        if let item = environment.library.items.first(where: { $0.id == model.id }) {
            activeSheet = sheet(item)
            return
        }
        isLoadingItem = true
        defer { isLoadingItem = false }
        do {
            activeSheet = sheet(try await environment.api.summary(id: model.id))
        } catch {
            actionFailed += 1
            actionError = error.localizedDescription
        }
    }

    /// The library card's title and text follow the paper.
    fileprivate func refreshLibraryItem() {
        Task { if let item = try? await environment.api.summary(id: model.id) { environment.library.upsert(item) } }
    }
}

enum PaperSheet: Identifiable, Hashable {
    case preview
    case issues
    case references
    case newFile
    case figure(PaperFigureKind)
    case droppedImage(PaperImageImport)
    case replaceImage(PaperFile)
    case renameFile(PaperFile)
    case settings
    case versions
    case share(Summary)
    case deletePaper(Summary)

    var id: String {
        switch self {
        case .preview: "preview"
        case .issues: "issues"
        case .references: "references"
        case .newFile: "new-file"
        case .figure(let kind): "figure:\(kind.rawValue)"
        case .droppedImage(let image): "dropped-image:\(image.id)"
        case .replaceImage(let file): "replace-image:\(file.path)"
        case .renameFile(let file): "rename:\(file.path)"
        case .settings: "settings"
        case .versions: "versions"
        case .share(let summary): "share:\(summary.id)"
        case .deletePaper(let summary): "delete:\(summary.id)"
        }
    }
}

/// "Saved", "Saving…" or why the last autosave failed, in the editor's corner.
private struct PaperSaveStatus: View {
    let state: PaperEditorModel.SaveState

    var body: some View {
        Group {
            switch state {
            case .saved: Label("Saved", systemImage: "checkmark.circle")
            case .edited: Label("Edited", systemImage: "pencil.circle")
            case .saving: Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
            case .failed(let message): Label("Not saved", systemImage: "exclamationmark.triangle.fill").help(message)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(state.isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .accessibilityIdentifier("paper-save-status")
    }
}

private extension PaperEditorModel.SaveState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
