import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// A LaTeX paper: the source editor and its compiled PDF. iPad and Mac show them side by side and
/// the preview recompiles after each autosave; iPhone shows the editor with the PDF one tap away
/// in a sheet. Edits autosave; leaving the paper saves them as one version.
struct PaperDetailView: View {
    let environment: AppEnvironment
    let title: String
    @State var model: PaperEditorModel
    /// The paper's saved versions; picking a past one shows its source and PDF read-only.
    @State var versions: DocumentVersionsModel
    @State var activeSheet: PaperSheet?
    @State var jump: PaperLineJump?
    /// Which of the open file's error lines the error button last went to; nil before the first tap.
    @State var errorStep: Int?
    @State var confirmsFileDeletion = false
    @State var isOpeningAction = false
    @State var isChecking = false
    @State var isLoadingItem = false
    @State var isSavingVersion = false
    @State var isImportingImage = false
    @State var actionError: String?
    @State var actionFailed = 0
    @Environment(\.dismiss) var dismiss
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

    var busyMessage: String? {
        if isImportingImage { return String(localized: "Importing image…") }
        if isOpeningAction { return String(localized: "Saving changes…") }
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
        .safeAreaInset(edge: .bottom) {
            if let paper = model.paper, paper.isTranslated, model.previewSource == nil {
                Button { Task { await openPaperAction(.language) } } label: {
                    Label(paper.translationOutdated == true ? String(localized: "Translation outdated — update before exporting") : String(localized: "Translated · Read-only"),
                          systemImage: paper.translationOutdated == true ? "arrow.clockwise" : "translate")
                        .font(.caption.weight(.semibold))
                        .padding(10)
                }
                .disabled(!model.isOwner)
                .accessibilityIdentifier("paper-translation-status")
            }
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
                        issues: editorIssues(in: file.path),
                        symbols: { [model] in model.shownSource.map(LaTeXSymbols.init) ?? LaTeXSymbols() },
                        onImageDrop: importDroppedImage
                    )
                }
            } else {
                ContentUnavailableView("No File Open", systemImage: "doc.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The error button and the save status share a row so they never overlap.
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 8) {
                if let file = model.selectedFile, !file.isImage {
                    errorButton(lines: errorLines(in: file.path))
                }
                Spacer(minLength: 0)
                if model.previewSource == nil, model.isOwner {
                    PaperSaveStatus(state: model.saveState, isCheckingReferences: model.isCheckingReferences)
                }
            }
            .padding(12)
        }
        .animation(.spring(duration: 0.3), value: model.selectedFile.map { errorLines(in: $0.path) })
        .onChange(of: model.selectedPath) { errorStep = nil }
        .sensoryFeedback(.selection, trigger: errorStep) { (_: Int?, step: Int?) in step != nil }
        .modifier(PaperImageDropTarget(isEnabled: model.canEdit && activeSheet == nil && busyMessage == nil, onDrop: importDroppedImage))
    }

    /// Goes to the open file's next error line, back to the first after the last.
    @ViewBuilder
    private func errorButton(lines: [Int]) -> some View {
        if !lines.isEmpty {
            Button {
                let next = errorStep.map { ($0 + 1) % lines.count } ?? 0
                errorStep = next
                jump = PaperLineJump(line: lines[next])
            } label: {
                Label {
                    if let errorStep, errorStep < lines.count {
                        Text("Error \(errorStep + 1) of \(lines.count) · Line \(lines[errorStep])")
                    } else {
                        Text(lines.count == 1 ? String(localized: "1 Error") : String(localized: "\(lines.count) Errors"))
                    }
                } icon: {
                    Image(systemName: lines.count > 1 ? "chevron.down.circle.fill" : "exclamationmark.triangle.fill")
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(lines.count > 1 ? "Go to Next Error" : "Go to Error")
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("paper-next-error")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let source = model.shownSource {
            ToolbarItem(placement: .principal) {
                fileMenu(source)
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
                    let errors = errorLines(in: file.path).count
                    Label(file.path, systemImage: errors > 0 ? "exclamationmark.triangle.fill" : file.path == source.mainFile ? "star.fill" : file.systemImage)
                        .badge(errors)
                        .tag(file.path)
                }
            }
            .pickerStyle(.inline)
            if model.canEdit {
                Divider()
                Button { activeSheet = .newFile } label: { Label("New File…", systemImage: "doc.badge.plus") }
                    .disabled(source.files.count >= PaperPath.maxFiles)
                    .accessibilityIdentifier("paper-new-file")
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
            fileMenuLabel(source)
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
            Button { Task { await openPaperAction(.export) } } label: { Label("Export…", systemImage: "arrow.up.doc") }
                .disabled(busyMessage != nil)
                .accessibilityIdentifier("paper-export")
            if model.isOwner {
                Divider()
                if model.canEdit, let source = model.source {
                    Button { activeSheet = .figure(.image) } label: { Label("Add Image…", systemImage: "photo.badge.plus") }
                        .disabled(source.files.count + 2 > PaperPath.maxFiles || busyMessage != nil)
                        .accessibilityIdentifier("paper-add-image")
                }
                Button { Task { await openPaperAction(.rendering) } } label: { Label("Rendering Options…", systemImage: "textformat") }
                    .accessibilityIdentifier("paper-rendering-options")
                if model.previewSource == nil {
                    Button { Task { await openPaperAction(.language) } } label: { Label("Language…", systemImage: "translate") }
                        .accessibilityIdentifier("paper-language")
                }
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
        .badge(errorCount)
        .accessibilityIdentifier("paper-more")
    }




}


enum PaperSheet: Identifiable, Hashable {
    case export
    case language
    case rendering
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
        case .export: "export"
        case .language: "language"
        case .rendering: "rendering"
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

/// "Saved", "Saving…", "Checking references…" once saved, or why the last autosave failed, in the
/// editor's corner.
private struct PaperSaveStatus: View {
    let state: PaperEditorModel.SaveState
    var isCheckingReferences = false

    var body: some View {
        Group {
            switch state {
            case .saved where isCheckingReferences:
                Label {
                    Text("Checking references…")
                } icon: {
                    ProgressView().controlSize(.mini)
                }
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
        .animation(.spring(duration: 0.3), value: isCheckingReferences)
        .accessibilityIdentifier("paper-save-status")
    }
}

private extension PaperEditorModel.SaveState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
