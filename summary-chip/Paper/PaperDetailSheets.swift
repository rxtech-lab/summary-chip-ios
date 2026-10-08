import SummaryKit
import SwiftUI

extension PaperDetailView {
    // MARK: Sheets

    @ViewBuilder
    func sheetContent(_ sheet: PaperSheet) -> some View {
        switch sheet {
        case .export:
            exportSheet
        case .language:
            languageSheet
        case .rendering:
            if let paper = model.paper {
                PaperRenderingSheet(api: environment.api, paper: paper) { fresh in
                    Task { await model.readingChanged(fresh) }
                }
            }
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

    @ViewBuilder private var exportSheet: some View {
        if let paper = model.paper {
            PaperExportSheet(api: environment.api, paper: paper, version: model.previewVersion, referenceErrors: model.referenceErrors.count) { format, language in
                await model.flush()
                if model.hasLocalChanges { throw PaperProjectError(String(localized: "Save your changes before exporting.")) }
                return try await environment.api.exportPaper(id: model.id, format: format, language: language, version: model.previewVersion)
            } onLanguageChanged: { fresh in
                Task { await model.readingChanged(fresh) }
                refreshLibraryItem()
            }
        }
    }

    @ViewBuilder private var languageSheet: some View {
        if let paper = model.paper {
            PaperLanguageSheet(api: environment.api, paper: paper) { fresh in
                Task { await model.readingChanged(fresh) }
                refreshLibraryItem()
            }
        }
    }
}
