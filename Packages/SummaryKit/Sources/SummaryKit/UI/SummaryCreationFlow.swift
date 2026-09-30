#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Source → options → generating → result, used by the app's "New Summary" sheet, the share
/// extension and the iMessage extension. Owns its NavigationStack; options live on a pushed
/// screen so the compose screen stays uncluttered.
public struct SummaryCreationFlow<Result: View>: View {
    let api: SummaryAPIClient
    let fixedInput: SummaryInput?
    let allowsFilePicking: Bool
    let title: String
    let onCancel: () -> Void
    let onCreated: (Summary) -> Void
    let result: (Summary) -> Result

    @State private var session = GenerationSession()
    @State private var options = GenerationOptionsStore.load()
    @State private var draft: String
    @State private var pickedPDF: SummaryInput?
    @State private var isImporting = false
    @State private var importError: String?

    public init(
        api: SummaryAPIClient,
        input: SummaryInput? = nil,
        initialText: String = "",
        allowsFilePicking: Bool = false,
        title: String = "New Summary",
        onCancel: @escaping () -> Void,
        onCreated: @escaping (Summary) -> Void = { _ in },
        @ViewBuilder result: @escaping (Summary) -> Result
    ) {
        self.api = api
        self.fixedInput = input
        self.allowsFilePicking = allowsFilePicking
        self.title = title
        self.onCancel = onCancel
        self.onCreated = onCreated
        self.result = result
        self._draft = State(initialValue: initialText)
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(for: OptionsRoute.self) { _ in
                    Form { GenerationOptionsSections(options: $options) }
                        .navigationTitle("Options")
                }
        }
        .interactiveDismissDisabled(session.isGenerating)
        .sensoryFeedback(trigger: session.state) { old, new in
            switch new {
            case .generating: if case .generating = old { nil } else { .impact(weight: .medium) }
            case .finished: .success
            case .failed: .error
            case .idle: nil
            }
        }
        .sensoryFeedback(.error, trigger: importError) { _, new in new != nil }
    }

    private struct OptionsRoute: Hashable {}

    private var navigationTitle: String {
        switch session.state {
        case .idle, .failed: title
        case .generating: "Generating…"
        case .finished: "Ready to share"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle:
            compose(error: nil)
        case .failed(let message):
            compose(error: message)
        case .generating(let stage):
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let input = currentInput {
                        SummaryInputPreview(input: input)
                    }
                    GenerationProgressView(stages: session.stages, current: stage)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .finished(let summary):
            result(summary)
        }
    }

    private func compose(error: String?) -> some View {
        Form {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section {
                if let fixedInput {
                    SummaryInputPreview(input: fixedInput)
                } else if let pickedPDF {
                    SummaryInputPreview(input: pickedPDF)
                    Button("Remove PDF", role: .destructive) { self.pickedPDF = nil }
                } else {
                    TextField("Paste a link or some text", text: $draft, axis: .vertical)
                        .lineLimit(3...10)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("new-summary-input")
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { draft = first }
                    }
                    .buttonBorderShape(.capsule)
                    if allowsFilePicking {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Choose a PDF…", systemImage: "doc.badge.plus")
                        }
                    }
                }
            } header: {
                Text("Source")
            } footer: {
                if let importError { Text(importError).foregroundStyle(.red) }
                else if fixedInput == nil, pickedPDF == nil { Text(draftHint) }
            }

            Section {
                NavigationLink(value: OptionsRoute()) {
                    LabeledContent("Options") {
                        Text(optionsSummary).lineLimit(1)
                    }
                }
            }

            Section {
                Button {
                    generate()
                } label: {
                    Label(error == nil ? "Generate summary" : "Try again", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(currentInput == nil)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("generate-summary")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
            importPDF(result)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch session.state {
        case .generating:
            ToolbarItem(placement: .cancellationAction) {
                Button("Stop", role: .cancel) { session.cancel() }
            }
        case .finished:
            ToolbarItem(placement: .cancellationAction) {
                Button("New") {
                    session.reset()
                    draft = ""
                    pickedPDF = nil
                }
                .opacity(fixedInput == nil ? 1 : 0)
                .disabled(fixedInput != nil)
            }
        default:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { onCancel() }
            }
        }
    }

    private var optionsSummary: String {
        [options.language == .auto ? nil : options.language.title,
         options.imageStyle.title,
         options.visibility.title,
         options.ttl == .never ? "Link never expires" : "Link: \(options.ttl.title)"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var draftHint: String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A web link, or any text you want summarised." }
        return ShareClassifier.singleURL(in: trimmed) != nil ? "The server will read this web page." : "The text will be summarised as-is."
    }

    private var currentInput: SummaryInput? {
        if let fixedInput { return fixedInput }
        if let pickedPDF { return pickedPDF }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = ShareClassifier.singleURL(in: trimmed) { return .url(url) }
        return .text(trimmed, title: nil)
    }

    private func generate() {
        guard let input = currentInput else { return }
        GenerationOptionsStore.save(options)
        session.start(input: input, options: options, api: api) { summary in
            onCreated(summary)
        }
    }

    private func importPDF(_ result: Swift.Result<URL, any Error>) {
        importError = nil
        do {
            let picked = try result.get()
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            let directory = FileManager.default.temporaryDirectory.appending(path: "SummaryChipImport", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "\(UUID().uuidString)-\(picked.lastPathComponent)")
            try FileManager.default.copyItem(at: picked, to: destination)
            pickedPDF = .pdf(fileURL: destination, filename: picked.lastPathComponent, sourceURL: nil)
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// Shown by extensions when no shared session exists.
public struct SignedOutNotice: View {
    let action: (() -> Void)?

    public init(action: (() -> Void)? = nil) { self.action = action }

    public var body: some View {
        ContentUnavailableView {
            Label("Sign in to Summary Chip", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("Open the Summary Chip app and sign in. This extension then uses the same account automatically.")
        } actions: {
            if let action {
                Button("Open Summary Chip", action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
#endif
