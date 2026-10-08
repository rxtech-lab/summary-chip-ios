import SummaryKit
import SwiftUI

extension PaperDetailView {
    // MARK: Actions

    func feedback(_ content: some View) -> some View {
        content
        .sensoryFeedback(.selection, trigger: model.selectedPath)
        .sensoryFeedback(.selection, trigger: activeSheet)
        .sensoryFeedback(.selection, trigger: isImportingImage) { _, importing in importing }
        .sensoryFeedback(.error, trigger: actionFailed)
        .sensoryFeedback(.error, trigger: model.failedCount)
        .sensoryFeedback(trigger: model.notice) { _, notice -> SensoryFeedback? in notice == nil ? nil : .success }
        .sensoryFeedback(.warning, trigger: model.compileIssues.count) { old, new in old == 0 && new > 0 }
        .sensoryFeedback(.warning, trigger: model.referenceErrors.count) { old, new in new > old }
    }

    @ViewBuilder
    func figureSheet(_ kind: PaperFigureKind, importedImage: PaperImageImport? = nil) -> some View {
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

    func importDroppedImage(_ providers: [NSItemProvider]) -> Bool {
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

    func fileMenuLabel(_ source: PaperSource) -> some View {
        let openPath = model.selectedPath ?? source.mainFile
        let openErrors = errorLines(in: openPath).count
        let otherErrors = source.files.reduce(0) { $1.path == openPath ? $0 : $0 + errorLines(in: $1.path).count }
        return
            HStack(spacing: 4) {
                Image(systemName: openErrors > 0 ? "exclamationmark.triangle.fill" : model.selectedFile?.systemImage ?? "doc.text")
                Text(openPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if openErrors + otherErrors > 0 {
                    Text("\(openErrors + otherErrors)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.red, in: Capsule())
                        .accessibilityLabel(Text("\(openErrors + otherErrors) errors"))
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(openErrors > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    }

    func open(_ path: String, line: Int? = nil) {
        model.selectedPath = path
        if let line { jump = PaperLineJump(line: line) }
    }

    /// What a new file starts with.
    static func starter(for path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        switch (path as NSString).pathExtension.lowercased() {
        case "tex": return "\\section{\(name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized)}\n\n"
        case "bib": return "% BibTeX entries\n"
        default: return ""
        }
    }

    func check() async {
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

    func openPaperAction(_ sheet: PaperSheet) async {
        guard busyMessage == nil else { return }
        isOpeningAction = true
        defer { isOpeningAction = false }
        await model.flush()
        guard !model.hasLocalChanges else {
            actionError = String(localized: "Save your changes before exporting or changing language.")
            actionFailed += 1
            return
        }
        activeSheet = sheet
    }

    func saveVersion() async {
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
    func openItem(_ sheet: (Summary) -> PaperSheet) async {
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
    func refreshLibraryItem() {
        Task { if let item = try? await environment.api.summary(id: model.id) { environment.library.upsert(item) } }
    }
}

extension PaperDetailView {
    /// The LaTeX errors and failed references in the open file, marked on their lines.
    func editorIssues(in path: String) -> [PaperEditorIssue] {
        let latex = model.shownIssues.compactMap { issue -> PaperEditorIssue? in
            guard issue.file == path, let line = issue.line else { return nil }
            return PaperEditorIssue(line: line, message: issue.message)
        }
        let references = model.isOwner ? model.referenceErrors.filter { $0.file == path }.map { reference in
            PaperEditorIssue(line: reference.line, message: reference.message.map { "\(reference.key): \($0)" } ?? String(localized: "\(reference.key): reference error"))
        } : []
        return latex + references
    }

    /// The lines of `path` with errors, top to bottom.
    func errorLines(in path: String) -> [Int] {
        Array(Set(editorIssues(in: path).map(\.line))).sorted()
    }

    /// LaTeX errors plus references that didn't hold up, counted on the More button.
    var errorCount: Int {
        model.shownIssues.count + (model.isOwner ? model.referenceErrors.count : 0)
    }
}
