import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

struct PaperExportSheet: View {
    let api: SummaryAPIClient
    let version: Int?
    let referenceErrors: Int
    let prepare: (PaperExportFormat, SummaryLanguage) async throws -> PaperExport
    let onLanguageChanged: (Paper) -> Void
    @State private var paper: Paper
    @State private var format: PaperExportFormat = .pdf
    @State private var language: SummaryLanguage
    @State private var translations: SummaryTranslations?
    @State private var showsLanguages = false
    @State private var showsRendering = false
    @State private var confirmsReferences = false
    @State private var isPreparing = false
    @State private var document: PaperExportDocument?
    @State private var errorMessage: String?
    @State private var exported = false
    @State private var finished = 0
    @Environment(\.dismiss) private var dismiss

    init(api: SummaryAPIClient, paper: Paper, version: Int?, referenceErrors: Int,
         prepare: @escaping (PaperExportFormat, SummaryLanguage) async throws -> PaperExport,
         onLanguageChanged: @escaping (Paper) -> Void) {
        self.api = api
        self.version = version
        self.referenceErrors = referenceErrors
        self.prepare = prepare
        self.onLanguageChanged = onLanguageChanged
        _paper = State(initialValue: paper)
        _language = State(initialValue: version == nil && paper.isTranslated ? SummaryLanguage(languageTag: paper.readingLanguage) ?? .auto : .auto)
    }

    private var translationReady: Bool {
        language == .auto || language == SummaryLanguage(languageTag: paper.writtenLanguage) || translations?.item(for: language)?.upToDate == true
    }

    var body: some View {
        NavigationStack {
            options
                .navigationTitle("Export Paper")
                .summaryInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(isPreparing)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { requestExport() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                            .fontWeight(.semibold)
                            .disabled(isPreparing || !translationReady)
                            .accessibilityIdentifier("paper-export-confirm")
                    }
                }
                .overlay {
                    if isPreparing { ActionStatusOverlay(String(localized: "Preparing export…")) }
                    if exported { ActionStatusOverlay(String(localized: "Exported"), isWorking: false).allowsHitTesting(false) }
                }
                .interactiveDismissDisabled(isPreparing)
                .confirmationDialog("Export with reference errors?", isPresented: $confirmsReferences, titleVisibility: .visible) {
                    Button("Export Anyway") { Task { await export() } }.accessibilityIdentifier("paper-download-anyway")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Some references have errors. The exported document will include them as they are.")
                }
                .fileExporter(isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } }),
                              document: document, contentType: format.contentType, defaultFilename: document?.filename) { result in
                    switch result {
                    case .success:
                        finished += 1
                        exported = true
                    case .failure(let error): errorMessage = error.localizedDescription
                    }
                }
                .statusAlert("Couldn't Export Paper", message: errorMessage) { errorMessage = nil }
                .sensoryFeedback(.selection, trigger: format)
                .sensoryFeedback(.selection, trigger: language)
                .sensoryFeedback(.selection, trigger: isPreparing) { _, preparing in preparing }
                .sensoryFeedback(.warning, trigger: confirmsReferences) { _, shown in shown }
                .sensoryFeedback(.success, trigger: finished)
                .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
        .summarySheetSize()
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showsLanguages) {
            PaperLanguageSheet(api: api, paper: paper) { fresh in
                paper = fresh
                language = fresh.isTranslated ? SummaryLanguage(languageTag: fresh.readingLanguage) ?? .auto : .auto
                onLanguageChanged(fresh)
                Task { await loadTranslations() }
            }
        }
        .sheet(isPresented: $showsRendering) {
            PaperRenderingSheet(api: api, paper: paper) { fresh in
                paper = fresh
                onLanguageChanged(fresh)
            }
        }
        .task { await loadTranslations() }
        .task(id: exported) {
            guard exported else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { exported = false }
        }
    }

    private var options: some View {
        Form {
            Section {
                Picker("Format", selection: $format) {
                    ForEach(PaperExportFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("paper-export-format")
                Picker("Language", selection: $language) {
                    Text("Original").tag(SummaryLanguage.auto)
                    ForEach(SummaryLanguage.translations.filter { $0 != SummaryLanguage(languageTag: paper.writtenLanguage) }) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("paper-export-language")
                if paper.isOwner, version == nil {
                    Button { showsLanguages = true } label: { Label("Manage Translations…", systemImage: "translate") }
                }
            } footer: {
                if !translationReady {
                    Text("This language needs a translation or an update. Open Manage Translations before exporting.")
                } else if format == .docx {
                    Text("Word keeps text, headings, tables and supported equations editable. Layout may differ from PDF. Custom diagrams need image replacements.")
                }
            }
            if paper.isOwner {
                Section {
                    Button { showsRendering = true } label: {
                        Label("Rendering Options…", systemImage: "textformat")
                    }
                    .accessibilityIdentifier("paper-export-rendering")
                } footer: {
                    Text(paper.rendering.enabled ? "Custom rendering applies to PDF and Word." : "Using the paper's original layout. Choose Rendering Options to customize PDF and Word.")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isPreparing)
    }

    private func loadTranslations() async {
        do { translations = try await api.paperTranslations(id: paper.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func requestExport() {
        if referenceErrors > 0 { confirmsReferences = true }
        else { Task { await export() } }
    }

    private func export() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let result = try await prepare(format, language)
            document = PaperExportDocument(data: result.data, format: format, title: paper.title)
        } catch { errorMessage = error.localizedDescription }
    }
}

struct PaperExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = PaperExportFormat.allCases.map(\.contentType)
    let data: Data
    let format: PaperExportFormat
    let filename: String

    init(data: Data, format: PaperExportFormat, title: String) {
        self.data = data
        self.format = format
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|%").union(.controlCharacters)).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        filename = String((cleaned.isEmpty ? "paper" : cleaned).prefix(120))
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        format = configuration.contentType == .pdf ? .pdf : .docx
        filename = "paper"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
