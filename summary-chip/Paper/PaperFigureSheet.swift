import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// Dedicated create view for an imported image, a TikZ diagram, or a pgfplots chart.
struct PaperFigureSheet: View {
    let source: PaperSource
    let kind: PaperFigureKind
    var replacing: PaperFile?
    let uploadImage: (String, Data) async throws -> PaperFile
    let onAdd: (String, String, String, PaperFile?) throws -> Void
    let onSave: () async throws -> Void

    @State private var path: String
    @State private var caption = ""
    @State private var code: String
    @State private var image: PaperFile?
    @State private var imageData: Data?
    @State private var didUpload = false
    @State private var showsImporter = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var imported = 0
    @State private var failed = 0
    @State private var didAdd = false

    init(
        source: PaperSource, kind: PaperFigureKind,
        replacing: PaperFile? = nil,
        importedImage: PaperImageImport? = nil,
        uploadImage: @escaping (String, Data) async throws -> PaperFile,
        onAdd: @escaping (String, String, String, PaperFile?) throws -> Void,
        onSave: @escaping () async throws -> Void
    ) {
        self.source = source
        self.kind = kind
        self.replacing = replacing
        self.uploadImage = uploadImage
        self.onAdd = onAdd
        self.onSave = onSave
        var number = 1
        while source.file("figures/figure-\(number).tex") != nil { number += 1 }
        _path = State(initialValue: replacing?.path ?? "figures/figure-\(number).tex")
        _code = State(initialValue: kind.starter)
        _image = State(initialValue: try? importedImage?.stagedFile(in: source, replacing: replacing))
        _imageData = State(initialValue: importedImage?.data)
    }

    private var problem: String? {
        if replacing != nil { return nil }
        if let problem = PaperPath.problem(with: path) { return problem }
        if !path.lowercased().hasSuffix(".tex") { return String(localized: "The figure file must end in .tex.") }
        if source.file(path) != nil { return String(localized: "There's already a file named \(path).") }
        let needed = kind == .image ? 2 : 1
        if source.files.count + needed > PaperPath.maxFiles { return String(localized: "A paper can have at most 60 files.") }
        if kind == .image, let image, source.file(image.path) != nil { return String(localized: "There's already a file named \(image.path).") }
        return nil
    }

    private var canSave: Bool {
        didAdd || (problem == nil && !isImporting && (kind == .image ? image != nil : !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    var body: some View {
        TripEditorScaffold(
            title: replacing != nil ? String(localized: "Replace Image") : kind == .image ? String(localized: "Add Image") : kind.title,
            canSave: canSave,
            savingMessage: replacing == nil ? String(localized: "Adding figure…") : String(localized: "Replacing image…"),
            save: save
        ) {
            Group {
                if let replacing {
                    Section {
                        LabeledContent("Image file", value: replacing.path)
                    } footer: {
                        Text("The existing figure uses the replacement image. Earlier versions keep the original.")
                    }
                } else {
                    Section {
                        TextField("Figure file", text: $path)
                            .autocorrectionDisabled()
                            .summaryInputCapitalization()
                            .accessibilityIdentifier("paper-figure-path")
                        TextField("Caption", text: $caption)
                            .accessibilityIdentifier("paper-figure-caption")
                    } footer: {
                        if let problem { Text(problem).foregroundStyle(.red) }
                        else { Text("The figure is included in the open TeX file, or the main file when another file is open.") }
                    }
                }
                if kind == .image {
                    imageSection
                } else {
                    Section {
                        TextEditor(text: $code)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .frame(minHeight: 220)
                            .accessibilityIdentifier("paper-figure-source")
                    } header: {
                        Text("LaTeX Source")
                    } footer: {
                        Text("The required package is added to the main file. You can keep editing the figure after saving.")
                    }
                }
            }
            .disabled(didAdd)
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: importTypes) { result in
            Task { await importImage(result) }
        }
        .overlay { if isImporting { ActionStatusOverlay(String(localized: "Importing image…")) } }
        .interactiveDismissDisabled(isImporting)
        .statusAlert("Couldn't Import Image", message: importError) { importError = nil }
        .sensoryFeedback(.selection, trigger: showsImporter)
        .sensoryFeedback(.success, trigger: imported)
        .sensoryFeedback(.error, trigger: failed)
        .accessibilityIdentifier("paper-figure-sheet")
    }

    private var importTypes: [UTType] {
        guard let replacing else { return [.png, .jpeg, .pdf] }
        switch replacing.fileExtension {
        case "png": return [.png]
        case "pdf": return [.pdf]
        default: return [.jpeg]
        }
    }

    private var imageSection: some View {
        Section {
            Button { showsImporter = true } label: {
                Label(image == nil ? String(localized: "Choose Image…") : String(localized: "Replace Image…"), systemImage: "photo.badge.plus")
            }
            .disabled(isImporting)
            .accessibilityIdentifier("paper-choose-image")
            if let image {
                PaperAssetView(file: image, data: imageData)
                    .frame(height: 180)
                Text(image.path).font(.caption.monospaced())
            }
        } footer: {
            Text("Choose or drop a PNG, JPEG or PDF, up to 10 MB each and 25 MB together per paper.")
        }
        .modifier(PaperImageDropTarget(isEnabled: !isImporting && !didAdd, onDrop: importDroppedImage))
    }

    private func save() async throws {
        if !didAdd {
            if kind == .image, !didUpload, let image, let imageData {
                self.image = try await uploadImage(image.path, imageData)
                didUpload = true
            }
            try onAdd(path, caption, code, image)
            didAdd = true
        }
        try await onSave()
    }

    private func importImage(_ result: Result<URL, Error>) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let url = try result.get()
            let importedImage = try await Task.detached { try PaperImageImport.read(url) }.value
            try stage(importedImage)
        } catch CocoaError.userCancelled {
        } catch {
            importError = error.localizedDescription
            failed += 1
        }
    }

    private func importDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard !isImporting, !didAdd else { return false }
        guard providers.count == 1, let provider = providers.first else {
            importError = String(localized: "Add one image at a time.")
            failed += 1
            return false
        }
        isImporting = true
        PaperImageImport.load(provider) { result in
            Task { @MainActor in
                defer { isImporting = false }
                do { try stage(result.get()) }
                catch {
                    importError = error.localizedDescription
                    failed += 1
                }
            }
        }
        return true
    }

    private func stage(_ importedImage: PaperImageImport) throws {
        image = try importedImage.stagedFile(in: source, replacing: replacing)
        imageData = importedImage.data
        didUpload = false
        imported += 1
    }
}
