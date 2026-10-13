import SummaryKit
import SwiftUI

/// The paper read as a native document instead of the PDF: text that reflows and grows with
/// the reader's font size (toolbar buttons, ⌘+/⌘−, or pinch), formulas set natively, and figures that
/// open full screen to zoom. It reads the LaTeX source, so it follows edits without compiling.
struct PaperReaderView: View {
    let source: PaperSource?
    /// A paper image file's bytes.
    let loadImage: @Sendable (String) async throws -> Data
    /// Images are cached per paper and version.
    let imageScope: String
    var onShowPDF: (() -> Void)?
    /// Draws a TikZ or pgfplots environment through LaTeX (a PDF); nil leaves a note in its place.
    var renderDrawing: (@Sendable (String) async throws -> Data)?
    /// The paper's reviews: selecting text offers **Add Review**, and reviewed passages are marked.
    var reviews: PaperReviewModel?
    @AppStorage(PaperReaderSettings.fontSizeKey) private var fontSize = PaperReaderSettings.defaultFontSize
    @AppStorage(PaperReaderSettings.serifKey) private var serif = true
    @State private var document: PaperReaderDocument?
    @State private var note: PaperReaderNote?
    @State private var figure: PaperFigureViewerItem?
    @State private var pinchStart: Double?
    @State private var reviewQuote: PaperReviewQuote?

    var body: some View {
        Group {
            if let document {
                content(document)
            } else {
                ProgressView("Reading paper…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source) { await read() }
        .sheet(item: $note) { note in
            if let document { PaperReaderNoteSheet(note: note, context: readerContext(document)) }
        }
        .paperFigureViewer(item: $figure)
        .sheet(item: $reviewQuote) { quote in
            if let reviews {
                PaperReviewComposeSheet(quote: quote.text, reviews: reviews, source: source)
            }
        }
        .sensoryFeedback(.selection, trigger: fontSize)
        .sensoryFeedback(.success, trigger: reviews?.changeCount ?? 0)
    }

    private func readerContext(_ document: PaperReaderDocument) -> PaperReaderContext {
        PaperReaderContext(
            document: document,
            fontSize: fontSize,
            serif: serif,
            imageScope: imageScope,
            assetKeys: Dictionary((source?.files ?? []).compactMap { file in file.asset.map { (file.path, $0.key) } }, uniquingKeysWith: { first, _ in first }),
            loadImage: loadImage,
            openFigure: { figure = $0 },
            showPDF: onShowPDF,
            renderDrawing: renderDrawing,
            addReview: reviews == nil ? nil : { quote in reviewQuote = PaperReviewQuote(text: quote) },
            reviewHighlights: (reviews?.unresolved ?? []).map { PaperReviewHighlight(quote: $0.quote, status: $0.status) }
        )
    }

    private func content(_ document: PaperReaderDocument) -> some View {
        let context = readerContext(document)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: fontSize * 0.9) {
                    ForEach(document.blocks) { block in
                        PaperBlockView(block: block, context: context)
                            .id(block.id)
                    }
                }
                #if os(macOS)
                .textSelection(.enabled)
                #endif
                .frame(maxWidth: fontSize * 42, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color.paperReaderBackground)
            .environment(\.openURL, OpenURLAction { url in open(url, in: document, proxy: proxy) })
            .simultaneousGesture(pinch)
            .accessibilityIdentifier("paper-reader")
        }
    }

    /// Pinching scales the text, in whole points.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? fontSize
                pinchStart = start
                fontSize = PaperReaderSettings.clamped((start * value.magnification).rounded())
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Citations and footnotes open a note; references scroll to what they name.
    private func open(_ url: URL, in document: PaperReaderDocument, proxy: ScrollViewProxy) -> OpenURLAction.Result {
        guard let link = PaperReaderLink(url) else { return .systemAction }
        switch link {
        case .citation(let keys): note = .citation(keys)
        case .footnote(let number): note = .footnote(number)
        case .reference(let key):
            guard let block = document.labels[key]?.block else { return .handled }
            scroll(to: block, in: document, proxy: proxy)
        case .block(let id): scroll(to: id, in: document, proxy: proxy)
        }
        return .handled
    }

    /// Nested blocks (an equation in a list) scroll to the top-level block holding them.
    private func scroll(to id: Int, in document: PaperReaderDocument, proxy: ScrollViewProxy) {
        let target = document.blocks.first { $0.contains(id) }?.id ?? id
        withAnimation(.smooth) { proxy.scrollTo(target, anchor: .top) }
    }

    /// Reads the source off the main thread; edits wait a moment so typing doesn't reread each key.
    private func read() async {
        guard let source else { return }
        if document != nil {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        let read = await Task.detached(priority: .userInitiated) { PaperReader.read(source) }.value
        guard !Task.isCancelled else { return }
        document = read
    }
}

// MARK: - Settings

nonisolated enum PaperReaderSettings {
    static let fontSizeKey = "paperReaderFontSize"
    static let serifKey = "paperReaderSerif"
    #if os(macOS)
    static let defaultFontSize: Double = 15
    #else
    static let defaultFontSize: Double = 17
    #endif
    static let fontSizes: ClosedRange<Double> = 11...34

    static func clamped(_ size: Double) -> Double { min(max(size, fontSizes.lowerBound), fontSizes.upperBound) }
}

/// Smaller and larger text, and the typeface, as toolbar items: the preview sheet's bar on
/// iPhone, the paper's bar on iPad and Mac, grouped in one capsule.
struct PaperReaderTextToolbar: ToolbarContent {
    @AppStorage(PaperReaderSettings.fontSizeKey) private var fontSize = PaperReaderSettings.defaultFontSize
    @AppStorage(PaperReaderSettings.serifKey) private var serif = true

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .summaryTrailing) {
            Button { fontSize = PaperReaderSettings.clamped(fontSize - 1) } label: {
                Label("Smaller Text", systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(fontSize <= PaperReaderSettings.fontSizes.lowerBound)
            .help("Smaller Text")
            .accessibilityIdentifier("paper-reader-smaller")
            Button { fontSize = PaperReaderSettings.clamped(fontSize + 1) } label: {
                Label("Larger Text", systemImage: "textformat.size.larger")
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(fontSize >= PaperReaderSettings.fontSizes.upperBound)
            .help("Larger Text")
            .accessibilityIdentifier("paper-reader-larger")
            Menu {
                Picker("Typeface", selection: $serif) {
                    Text("Serif").tag(true)
                    Text("Sans Serif").tag(false)
                }
                .pickerStyle(.inline)
                Button("Default Size") { fontSize = PaperReaderSettings.defaultFontSize }
                    .disabled(fontSize == PaperReaderSettings.defaultFontSize)
            } label: {
                Label("Text Options", systemImage: "textformat")
            }
            .menuIndicator(.hidden)
            .help("Text Options")
            .accessibilityIdentifier("paper-reader-text-options")
        }
    }
}

extension Color {
    #if os(macOS)
    static let paperReaderBackground = Color(nsColor: .textBackgroundColor)
    #else
    static let paperReaderBackground = Color(uiColor: .systemBackground)
    #endif
}

// MARK: - Context

/// What every block needs to draw: the document for references, the reader's type settings,
/// and where images come from.
struct PaperReaderContext {
    let document: PaperReaderDocument
    let fontSize: CGFloat
    let serif: Bool
    let imageScope: String
    /// Asset keys by path: a replaced image gets a new key, so it isn't served from the cache.
    let assetKeys: [String: String]
    let loadImage: @Sendable (String) async throws -> Data
    let openFigure: (PaperFigureViewerItem) -> Void
    let showPDF: (() -> Void)?
    /// Compiles a drawing's LaTeX to a PDF; nil when the reader can't ask the server.
    var renderDrawing: (@Sendable (String) async throws -> Data)?
    /// Called with the selected passage when the reader chooses **Add Review**; nil hides it.
    var addReview: ((String) -> Void)?
    /// Passages with an unresolved review, marked in the text.
    var reviewHighlights: [PaperReviewHighlight] = []
    /// Theorem bodies are italic.
    var baseStyle: PaperTextStyle = []

    func with(_ style: PaperTextStyle) -> PaperReaderContext {
        var context = self
        context.baseStyle = style
        return context
    }

    func font(_ scale: CGFloat = 1, style: PaperTextStyle = []) -> Font {
        let design: Font.Design = style.contains(.monospace) ? .monospaced : style.contains(.sansSerif) || !serif ? .default : .serif
        var font = Font.system(size: fontSize * scale, weight: style.contains(.bold) ? .bold : .regular, design: design)
        if style.contains(.italic) { font = font.italic() }
        if style.contains(.smallCaps) { font = font.smallCaps() }
        return font
    }

    /// Paragraph content as styled text: formulas inline, citations, references and footnote
    /// marks as links the reader handles.
    func text(_ spans: [PaperSpan], scale: CGFloat = 1, style extra: PaperTextStyle = []) -> AttributedString {
        let size = fontSize * scale
        var result = AttributedString()
        for span in spans {
            let style = span.style.union(baseStyle).union(extra)
            switch span.kind {
            case .text(let text):
                result += styled(text, style, scale: scale)
            case .math(let nodes, _):
                for run in PaperMath.runs(nodes) {
                    var piece = AttributedString(run.text)
                    let font: MathFont = style.contains(.bold) ? (run.font == .italic ? .boldItalic : .bold) : run.font
                    piece.font = PaperMathFont.font(font, size: size * run.scale)
                    if run.baseline != 0 { piece.baselineOffset = run.baseline * size }
                    result += piece
                }
            case .link(let label, let url):
                var piece = styled(label, style, scale: scale)
                piece.link = URL(string: url)
                result += piece
            case .citation(let keys, let form, let note):
                var piece = styled(document.citationText(keys, form: form, note: note), style, scale: scale)
                piece.link = PaperReaderLink.citation(keys).url
                result += piece
            case .reference(let key, let form):
                var piece = styled(document.referenceText(key, form: form), style, scale: scale)
                piece.link = PaperReaderLink.reference(key).url
                result += piece
            case .footnote(let number):
                var piece = AttributedString("\(number)")
                piece.font = font(scale * 0.65)
                piece.baselineOffset = size * 0.35
                piece.link = PaperReaderLink.footnote(number).url
                result += piece
            case .lineBreak:
                result += AttributedString("\n")
            }
        }
        return result
    }

    private func styled(_ text: String, _ style: PaperTextStyle, scale: CGFloat) -> AttributedString {
        var piece = AttributedString(text)
        piece.font = font(scale, style: style)
        if style.contains(.underline) { piece.underlineStyle = Text.LineStyle.single }
        if style.contains(.strikethrough) { piece.strikethroughStyle = Text.LineStyle.single }
        return piece
    }
}

/// Links inside the reader's text, opened by `PaperReaderView` rather than the system.
nonisolated enum PaperReaderLink: Equatable {
    case citation([String])
    case reference(String)
    case footnote(Int)
    case block(Int)

    private static let scheme = "chippy-reader"

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .citation(let keys): components.host = "cite"; components.queryItems = keys.map { URLQueryItem(name: "key", value: $0) }
        case .reference(let key): components.host = "ref"; components.queryItems = [URLQueryItem(name: "key", value: key)]
        case .footnote(let number): components.host = "footnote"; components.queryItems = [URLQueryItem(name: "n", value: String(number))]
        case .block(let id): components.host = "block"; components.queryItems = [URLQueryItem(name: "id", value: String(id))]
        }
        return components.url
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = (components.queryItems ?? []).compactMap(\.value)
        switch components.host {
        case "cite": self = .citation(values)
        case "ref": guard let key = values.first else { return nil }; self = .reference(key)
        case "footnote": guard let number = values.first.flatMap(Int.init) else { return nil }; self = .footnote(number)
        case "block": guard let id = values.first.flatMap(Int.init) else { return nil }; self = .block(id)
        default: return nil
        }
    }
}

/// A passage selected for a review, waiting for its comment.
struct PaperReviewQuote: Identifiable, Hashable {
    let id = UUID()
    let text: String
}

nonisolated enum PaperReaderNote: Identifiable, Hashable {
    case citation([String])
    case footnote(Int)

    var id: String {
        switch self {
        case .citation(let keys): "cite:" + keys.joined(separator: ",")
        case .footnote(let number): "footnote:\(number)"
        }
    }
}

/// A tapped citation's bibliography entries, or a footnote.
private struct PaperReaderNoteSheet: View {
    let note: PaperReaderNote
    let context: PaperReaderContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch note {
                    case .citation(let keys):
                        ForEach(keys, id: \.self) { key in entry(key) }
                    case .footnote(let number):
                        let spans = context.document.footnotes.indices.contains(number - 1) ? context.document.footnotes[number - 1] : []
                        Text(context.text(spans))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(title)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("paper-reader-note")
    }

    private var title: String {
        switch note {
        case .citation(let keys): keys.count == 1 ? String(localized: "Reference") : String(localized: "References")
        case .footnote(let number): String(localized: "Footnote \(number)")
        }
    }

    @ViewBuilder
    private func entry(_ key: String) -> some View {
        if let entry = context.document.bibEntry(key) {
            VStack(alignment: .leading, spacing: 8) {
                Text("[\(entry.number)]").font(context.font(0.85, style: .bold)).foregroundStyle(.secondary)
                Text(context.text(entry.text))
                if let url = entry.url.flatMap(URL.init(string:)) {
                    Button { openURL(url) } label: { Label("Open Link", systemImage: "safari") }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            Label("“\(key)” isn't in the paper's bibliography.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}

private extension PaperBlock {
    /// Whether this block is `id` or holds it.
    func contains(_ id: Int) -> Bool {
        if self.id == id { return true }
        switch kind {
        case .quote(let blocks), .abstract(let blocks): return blocks.contains { $0.contains(id) }
        case .theorem(let theorem): return theorem.blocks.contains { $0.contains(id) }
        case .list(let list): return list.items.contains { $0.blocks.contains { $0.contains(id) } }
        default: return false
        }
    }
}
