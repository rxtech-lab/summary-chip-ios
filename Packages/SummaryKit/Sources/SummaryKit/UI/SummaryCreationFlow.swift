#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Source → options → generating → result, used by the app's "New Summary" sheet, the share
/// extension and the iMessage extension. Owns its NavigationStack; options live on a pushed
/// screen so the compose screen stays uncluttered.
public struct SummaryCreationFlow<Result: View>: View {
    let api: SummaryAPIClient
    let fixedInput: SummaryInput?
    let sourceFile: URL?
    let sourceFilename: String?
    let initialFile: DroppedSummaryFile?
    let allowsFilePicking: Bool
    let title: String
    let onCancel: () -> Void
    let onCreated: (Summary) -> Void
    let onTopUp: (() -> Void)?
    /// Free summaries left today, shown as a badge on the Generate button; nil hides it.
    let freeSummariesRemaining: Int?
    let result: (Summary) -> Result

    @State private var session = GenerationSession()
    @State private var options = GenerationOptionsStore.load()
    @State private var draft: String
    @State private var pickedDocument: SummaryInput?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var isReadingFile = false
    @State private var isDropTargeted = false
    /// How the picked or dropped file is kept with the summary once it's created.
    @State private var pickedLink: PickedLink?
    @State private var importTask: Task<Void, Never>?
    @State private var didImportInitialFile = false
    @Environment(\.openURL) private var openURL

    public init(
        api: SummaryAPIClient,
        input: SummaryInput? = nil,
        sourceFile: URL? = nil,
        sourceFilename: String? = nil,
        initialText: String = "",
        initialFile: DroppedSummaryFile? = nil,
        allowsFilePicking: Bool = false,
        title: String = "New Summary",
        onCancel: @escaping () -> Void,
        onCreated: @escaping (Summary) -> Void = { _ in },
        onTopUp: (() -> Void)? = nil,
        freeSummariesRemaining: Int? = nil,
        @ViewBuilder result: @escaping (Summary) -> Result
    ) {
        self.api = api
        self.fixedInput = input
        self.sourceFile = sourceFile
        self.sourceFilename = sourceFilename
        self.initialFile = initialFile
        self.allowsFilePicking = allowsFilePicking
        self.title = title
        self.onCancel = onCancel
        self.onCreated = onCreated
        self.onTopUp = onTopUp
        self.freeSummariesRemaining = freeSummariesRemaining
        self.result = result
        self._draft = State(initialValue: initialText)
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .summaryInlineNavigationTitle()
                .toolbar { toolbar }
                .navigationDestination(for: OptionsRoute.self) { _ in
                    Form { GenerationOptionsSections(options: $options) }
                        .formStyle(.grouped)
                        .navigationTitle("Options")
                }
        }
        .summarySheetSize()
        .interactiveDismissDisabled(session.isGenerating || isReadingFile)
        .overlay {
            if isReadingFile {
                ActionStatusOverlay("Reading file…", isWorking: true)
            } else if session.isGenerating, case .generating(let stage) = session.state {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    VStack(spacing: 20) {
                        GenerationProgressView(stages: session.stages, current: stage)
                        Button("Stop", role: .cancel) { session.cancel() }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(24)
                }
                .accessibilityIdentifier("generation-status-overlay")
            }
        }
        .sheet(item: $session.unreadablePage) { page in
            OpenInSafariSheet(page: page, onSummariseText: summariseTextInstead) {
                session.unreadablePage = nil
            }
        }
        .statusAlert("Couldn't Read File", message: importError) { importError = nil }
        .statusAlert("Couldn't Create Summary", message: session.needsTopUp ? nil : failureMessage) { session.reset() }
        .alert("Not Enough Points", isPresented: topUpAlertPresented, presenting: failureMessage) { _ in
            Button(onTopUp == nil ? "Open Chippy" : "Top Up") {
                session.reset()
                if let onTopUp { onTopUp() }
                else if let url = URL(string: "summarychip://top-up") { openURL(url) }
            }
            Button("Later", role: .cancel) { session.reset() }
        } message: { message in
            Text(message)
        }
        .task {
            // A file dropped on or opened into the app starts the flow already loaded.
            guard !didImportInitialFile, let initialFile else { return }
            didImportInitialFile = true
            importDocument(at: initialFile.url, keepsOriginal: !initialFile.isStagedCopy)
        }
        .onDisappear {
            if !didImportInitialFile { initialFile?.discard() }
            importTask?.cancel()
            importTask = nil
            session.cancel()
            clearPickedDocument()
            if let sourceFile { LocalDocument.discardCopy(sourceFile) }
        }
        .sensoryFeedback(trigger: session.state) { old, new in
            switch new {
            case .generating: if case .generating = old { nil } else { .impact(weight: .medium) }
            case .finished: .success
            case .failed: .error
            case .idle: nil
            }
        }
        .sensoryFeedback(.error, trigger: importError) { _, new in new != nil }
        .sensoryFeedback(.warning, trigger: session.unreadablePage) { _, new in new != nil }
    }

    private var failureMessage: String? {
        if case .failed(let message) = session.state { message } else { nil }
    }

    private var topUpAlertPresented: Binding<Bool> {
        Binding(get: { session.needsTopUp && failureMessage != nil }, set: { if !$0 { session.reset() } })
    }

    private struct OptionsRoute: Hashable {}

    private enum PickedLink {
        /// The original stays where it is; only a bookmark to it is saved.
        case bookmark(Data, filename: String)
        /// The original couldn't be referenced (a drop on iOS); a staged copy is saved instead.
        case copy(URL, filename: String)
    }

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
        case .generating:
            compose(error: nil).disabled(true)
        case .finished(let summary):
            result(summary)
        }
    }

    private func compose(error: String?) -> some View {
        Form {
            Section {
                if let fixedInput {
                    SummaryInputPreview(input: fixedInput)
                } else if let pickedDocument {
                    SummaryInputPreview(input: pickedDocument)
                    Button(role: .destructive) {
                        clearPickedDocument()
                    } label: { Label("Remove file", systemImage: "xmark.circle") }
                } else {
                    TextField("Paste a link or some text", text: $draft, axis: .vertical)
                        .lineLimit(3...10)
                        .summaryInputCapitalization()
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("new-summary-input")
                    #if os(iOS)
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { draft = first }
                    }
                    .buttonBorderShape(.capsule)
                    #endif
                    if allowsFilePicking {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Choose a file…", systemImage: "doc.badge.plus")
                            .accessibilityIdentifier("choose-summary-file")
                        }
                    }
                }
            } header: {
                Text("Source")
            } footer: {
                if fixedInput == nil, pickedDocument == nil {
                    Text(allowsFilePicking ? "A web link, text, or drop or choose a PDF, document, text, Markdown or code file." : draftHint)
                } else if sourceFile != nil {
                    Text("Read on this device; \(savedToAccount). A copy of the file stays on this device.")
                } else if case .copy = pickedLink {
                    Text("Read on this device; \(savedToAccount). A copy of the file stays on this device.")
                } else if pickedDocument != nil {
                    Text("Read on this device; \(savedToAccount). The original file stays linked on this device.")
                }
            }

            if offersKeepingSourceText {
                Section {
                    Toggle(isOn: $options.keepsSourceText) {
                        Label("Keep source text", systemImage: "doc.plaintext")
                    }
                    .sensoryFeedback(.selection, trigger: options.keepsSourceText)
                    .accessibilityIdentifier("keep-source-text")
                } footer: {
                    Text("Saves the file's text with the summary, formatted as a document you can read later from the summary's toolbar. Free with your free summaries; after that, formatting uses points, and without points the plain text is kept. Only you can open it.")
                }
            }

            Section {
                NavigationLink(value: OptionsRoute()) {
                    LabeledContent("Options") {
                        Text(optionsSummary).lineLimit(1)
                    }
                }
            }

            #if os(iOS)
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
            #endif
        }
        .formStyle(.grouped)
        .disabled(isReadingFile)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: LocalDocument.contentTypes) { result in
            importFile(result)
        }
        .summaryDropDestination(isEnabled: acceptsDrops) { isDropTargeted = $0 } onFile: { file in
            importDocument(at: file.url, keepsOriginal: !file.isStagedCopy)
        } onLink: { url in
            clearPickedDocument()
            draft = url.absoluteString
        }
        .overlay {
            if isDropTargeted { SummaryDropHighlight() }
        }
    }

    private var acceptsDrops: Bool {
        allowsFilePicking && fixedInput == nil && !isReadingFile && !session.isGenerating
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
                    clearPickedDocument()
                }
                .opacity(fixedInput == nil ? 1 : 0)
                .disabled(fixedInput != nil)
            }
        default:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { onCancel() }.disabled(isReadingFile)
            }
            #if os(macOS)
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    generate()
                } label: {
                    Label(generationActionTitle, systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentInput == nil)
                .badge(freeSummariesRemaining ?? 0)
                .help(freeSummariesBadgeHelp)
                .accessibilityIdentifier("generate-summary")
            }
            #endif
        }
    }

    private var freeSummariesBadgeHelp: String {
        guard let freeSummariesRemaining, freeSummariesRemaining > 0 else { return "" }
        return freeSummariesRemaining == 1 ? "1 free summary left today" : "\(freeSummariesRemaining) free summaries left today"
    }

    private var generationActionTitle: String {
        if case .failed = session.state { return "Try again" }
        return "Generate summary"
    }

    private var optionsSummary: String {
        [options.language == .auto ? nil : options.language.title,
         options.imageStyle.title,
         options.visibility.title,
         options.ttl == .never ? "Link never expires" : "Link: \(options.ttl.title)"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Links and text always keep their source; a file read on this device only when the user opts in.
    private var offersKeepingSourceText: Bool {
        switch currentInput {
        case .localFile: true
        case .pdf(_, _, let sourceURL): sourceURL == nil
        default: false
        }
    }

    private var savedToAccount: String {
        offersKeepingSourceText && options.keepsSourceText
            ? "the summary and the file's text are saved to your account"
            : "only the summary is saved to your account"
    }

    private var draftHint: String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A web link, or any text you want summarised." }
        return ShareClassifier.singleURL(in: trimmed) != nil ? "The server will read this web page." : "The text will be summarised as-is."
    }

    private var currentInput: SummaryInput? {
        if let fixedInput { return fixedInput }
        if let pickedDocument { return pickedDocument }
        return ShareClassifier.classify(typed: draft)
    }

    /// Offered when the link inside pasted text can't be read anywhere.
    private var summariseTextInstead: (() -> Void)? {
        guard case .text = currentInput else { return nil }
        return {
            session.unreadablePage = nil
            generate(followLinks: false)
        }
    }

    private func generate(followLinks: Bool = true) {
        guard let input = currentInput else { return }
        GenerationOptionsStore.save(options)
        var options = options
        if !offersKeepingSourceText { options.keepsSourceText = false }
        session.start(input: input, options: options, api: api, followLinks: followLinks) { summary in
            onCreated(summary)
            do {
                let store = LocalFileStore()
                switch pickedLink {
                case .bookmark(let bookmark, let filename):
                    try store.saveBookmark(bookmark, filename: filename, summaryID: summary.id)
                case .copy(let file, let filename):
                    try store.saveCopy(of: file, filename: filename, summaryID: summary.id)
                case nil:
                    guard let sourceFile else { break }
                    try store.saveCopy(of: sourceFile, filename: sourceFilename ?? sourceFile.lastPathComponent, summaryID: summary.id)
                }
            } catch {
                importError = "Your summary was created, but the local file couldn't be linked. \(error.localizedDescription)"
            }
        }
    }

    private func clearPickedDocument() {
        if case .copy(let file, _) = pickedLink { LocalDocument.discardCopy(file) }
        pickedLink = nil
        pickedDocument = nil
        options.keepsSourceText = false
    }

    private func importFile(_ result: Swift.Result<URL, any Error>) {
        importError = nil
        guard case .success(let picked) = result else {
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                importError = error.localizedDescription
            }
            return
        }
        importDocument(at: picked, keepsOriginal: true)
    }

    /// Reads the file here, on the device. `keepsOriginal` bookmarks the user's file; otherwise
    /// `url` is a staged copy that is kept with the summary.
    private func importDocument(at url: URL, keepsOriginal: Bool) {
        importError = nil
        importTask?.cancel()
        isReadingFile = true
        importTask = Task {
            defer {
                isReadingFile = false
                importTask = nil
            }
            do {
                let (document, bookmark) = try await Task.detached {
                    if keepsOriginal {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let bookmark = try LocalFileStore.bookmark(for: url)
                        let staged = try LocalDocument.copyForReading(url)
                        defer { LocalDocument.discardCopy(staged) }
                        return (try LocalDocument.read(fileURL: staged, filename: url.lastPathComponent), Optional(bookmark))
                    }
                    return (try LocalDocument.read(fileURL: url), nil)
                }.value
                guard !Task.isCancelled else {
                    if !keepsOriginal { LocalDocument.discardCopy(url) }
                    return
                }
                clearPickedDocument()
                pickedDocument = .localFile(document)
                pickedLink = bookmark.map { .bookmark($0, filename: document.filename) } ?? .copy(url, filename: document.filename)
            } catch {
                if !keepsOriginal { LocalDocument.discardCopy(url) }
                importError = error.localizedDescription
            }
        }
    }
}

/// Shown by extensions when no shared session exists.
public struct SignedOutNotice: View {
    let action: (() -> Void)?

    public init(action: (() -> Void)? = nil) { self.action = action }

    public var body: some View {
        ContentUnavailableView {
            Label("Sign in to Chippy", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("Open the Chippy app and sign in. This extension then uses the same account automatically.")
        } actions: {
            if let action {
                Button("Open Chippy", action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
#endif
