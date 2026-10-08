import SummaryKit
import SwiftUI

/// Starts a LaTeX paper from a template; it opens in the editor once created.
struct NewPaperSheet: View {
    let api: SummaryAPIClient
    let onCreated: (Paper) -> Void

    @State private var title = ""
    @State private var template: PaperTemplate = .article
    @State private var compiler: PaperCompiler = .pdflatex
    @State private var visibility: SummaryVisibility = .private

    var body: some View {
        TripEditorScaffold(
            title: String(localized: "New Paper"),
            canSave: title.nilIfBlank != nil,
            savingMessage: String(localized: "Creating paper…"),
            save: create
        ) {
            Section {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("new-paper-title")
            }
            Section("Template") {
                Picker("Template", selection: $template) {
                    ForEach(PaperTemplate.allCases) { template in
                        Label {
                            Text(template.title)
                            Text(template.detail)
                        } icon: {
                            Image(systemName: template.systemImage)
                        }
                        .tag(template)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Picker("Engine", selection: $compiler) {
                    ForEach(PaperCompiler.allCases) { Text($0.title).tag($0) }
                }
                Picker("Visibility", selection: $visibility) {
                    ForEach(SummaryVisibility.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Your agent can write and edit the paper too, through Chippy's MCP server.")
            }
        }
    }

    private func create() async throws {
        let paper = try await api.createPaper(title: title.nilIfBlank ?? title, template: template, compiler: compiler, visibility: visibility)
        onCreated(paper)
    }
}

/// Adds a file to the paper, or renames one (`renaming`).
struct PaperFileSheet: View {
    let source: PaperSource
    var renaming: PaperFile?
    let onSave: (String) -> Void

    @State private var folder: String
    @State private var name: String

    init(source: PaperSource, renaming: PaperFile? = nil, onSave: @escaping (String) -> Void) {
        self.source = source
        self.renaming = renaming
        self.onSave = onSave
        _folder = State(initialValue: renaming?.folder ?? (source.files.contains { $0.folder == "sections" } ? "sections" : ""))
        _name = State(initialValue: renaming?.name ?? "")
    }

    private var path: String {
        let trimmedFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).trimmingCharacters(in: .whitespaces)
        var file = name.trimmingCharacters(in: .whitespaces)
        if !file.isEmpty, !file.contains(".") { file += ".tex" }
        return trimmedFolder.isEmpty ? file : "\(trimmedFolder)/\(file)"
    }

    private var problem: String? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if path != renaming?.path, source.file(path) != nil { return String(localized: "There's already a file named \(path).") }
        if renaming == nil, source.files.count >= PaperPath.maxFiles { return String(localized: "A paper can have at most \(PaperPath.maxFiles) files.") }
        let ext = (path as NSString).pathExtension.lowercased()
        if renaming == nil, PaperPath.imageExtensions.contains(ext) { return String(localized: "Use Add Image to import a PNG, JPEG or PDF.") }
        if let renaming, renaming.isImage, ext != renaming.fileExtension,
           !(Set(["jpg", "jpeg"]).contains(ext) && Set(["jpg", "jpeg"]).contains(renaming.fileExtension)) {
            return String(localized: "Keep the image's original file extension.")
        }
        if let renaming, !renaming.isImage, PaperPath.imageExtensions.contains(ext) { return String(localized: "A text file can't be renamed as an image.") }
        return PaperPath.problem(with: path)
    }

    var body: some View {
        TripEditorScaffold(
            title: renaming == nil ? String(localized: "New File") : String(localized: "Rename File"),
            canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil && path != renaming?.path,
            savingMessage: String(localized: "Saving…"),
            save: { onSave(path) }
        ) {
            Section {
                TextField("Folder (optional)", text: $folder, prompt: Text("sections"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("paper-file-folder")
                TextField("File name", text: $name, prompt: Text("results.tex"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("paper-file-name")
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else if !path.isEmpty {
                    Text(renaming == nil
                         ? String(localized: "Include it from your main file with \\input{\((path as NSString).deletingPathExtension)}.")
                         : String(localized: "Update any \\input or \\include that points at the old name."))
                }
            }
        }
        .summaryInputCapitalization()
    }
}

/// The paper's title in the library and its TeX engine.
struct PaperSettingsSheet: View {
    let source: PaperSource
    let onSave: (String, PaperCompiler) -> Void

    @State private var title: String
    @State private var compiler: PaperCompiler

    init(source: PaperSource, onSave: @escaping (String, PaperCompiler) -> Void) {
        self.source = source
        self.onSave = onSave
        _title = State(initialValue: source.title)
        _compiler = State(initialValue: source.compiler)
    }

    var body: some View {
        TripEditorScaffold(
            title: String(localized: "Paper Settings"),
            canSave: title.nilIfBlank != nil && (title != source.title || compiler != source.compiler),
            save: { onSave(title.nilIfBlank ?? title, compiler) }
        ) {
            Section {
                TextField("Title", text: $title)
            } footer: {
                Text("The title in your library. The title printed on the paper is the \\title in your main file.")
            }
            Section("Engine") {
                Picker("Engine", selection: $compiler) {
                    ForEach(PaperCompiler.allCases) { engine in
                        VStack(alignment: .leading) {
                            Text(engine.title)
                            Text(engine.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(engine)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }
}

/// The LaTeX errors of the last compile or check; choosing one opens its file.
struct PaperIssuesSheet: View {
    let issues: [LatexIssue]
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(issues) { issue in
                Button {
                    if let file = issue.file { onOpen(file) }
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.message)
                            if let location = issue.location {
                                Text(location)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(issue.file == nil)
            }
            .overlay {
                if issues.isEmpty {
                    ContentUnavailableView("No LaTeX Errors", systemImage: "checkmark.seal", description: Text("The paper compiles."))
                }
            }
            .navigationTitle("LaTeX Errors")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .summarySheetSize()
        .accessibilityIdentifier("paper-issues")
    }
}

/// iPhone: the compiled PDF in a sheet over the editor.
struct PaperPreviewSheet: View {
    let model: PaperEditorModel
    let onShowIssues: () -> Void
    var onShowReferences: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PaperPreviewPane(model: model, onShowIssues: onShowIssues, onShowReferences: onShowReferences)
                .navigationTitle(model.shownSource?.title ?? String(localized: "Preview"))
                .summaryInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}

/// The compiled PDF with its compile status: what's compiling, and the errors when it failed.
/// References that failed their check are highlighted in it, with their count below.
struct PaperPreviewPane: View {
    let model: PaperEditorModel
    let onShowIssues: () -> Void
    var onShowReferences: () -> Void = {}

    var body: some View {
        ZStack {
            if let data = model.shownPDF {
                PaperPDFView(data: data, flaggedReferences: model.referenceErrors)
            } else if model.isShownCompiling {
                ProgressView("Compiling…")
            } else if !model.shownIssues.isEmpty {
                ContentUnavailableView("No PDF", systemImage: "exclamationmark.triangle", description: Text("LaTeX stopped at an error."))
            } else if let error = model.compileError {
                ContentUnavailableView("Preview Unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ContentUnavailableView("No Preview Yet", systemImage: "doc.richtext")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if model.isShownCompiling, model.shownPDF != nil {
                Label("Compiling…", systemImage: "hourglass")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
                    .accessibilityIdentifier("paper-compiling")
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                PaperReferenceStatusButton(model: model, action: onShowReferences)
                if !model.shownIssues.isEmpty {
                    latexIssuesButton
                }
            }
            .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.2), value: model.isShownCompiling)
        .animation(.easeInOut(duration: 0.2), value: model.referenceErrors.count)
    }

    private var latexIssuesButton: some View {
        Button(action: onShowIssues) {
            Label(model.shownIssues.count == 1 ? String(localized: "1 LaTeX error") : String(localized: "\(model.shownIssues.count) LaTeX errors"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityIdentifier("paper-issues-button")
    }
}
