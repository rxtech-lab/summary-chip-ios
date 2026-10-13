#if DEBUG
import ImageIO
import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// The native paper reader on fixed LaTeX, for UI tests that compare its screenshots with
/// reference images: launch with `--preview-paper-reader` and `--reader-fixture text|math|figures|reviews`.
/// The `reviews` fixture has canned reviews (one waiting, one finished by an agent) kept in
/// memory; `--reader-open compose|reviews|diff` opens that sheet at once. The text size starts at
/// its default on every launch so the screenshots don't depend on the last run.
struct PaperReaderPreviewHost: View {
    private enum Opening: String { case compose, reviews, diff }

    private let fixture: PaperReaderFixture
    private let image: Data
    private let opening: Opening?
    @State private var reviews: PaperReviewModel?
    @State private var showsReviews = false
    @State private var composeQuote: PaperReviewQuote?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        fixture = value("--reader-fixture").flatMap(PaperReaderFixture.init(rawValue:)) ?? .text
        opening = value("--reader-open").flatMap(Opening.init(rawValue:))
        UserDefaults.standard.removeObject(forKey: PaperReaderSettings.fontSizeKey)
        UserDefaults.standard.removeObject(forKey: PaperReaderSettings.serifKey)
        image = Self.chartPNG()
        if fixture == .reviews {
            _reviews = State(initialValue: PaperReviewModel(backend: FixturePaperReviewBackend(source: fixture.source)))
        }
    }

    var body: some View {
        let image = image
        NavigationStack {
            PaperReaderView(
                source: fixture.source,
                loadImage: { _ in image },
                imageScope: "preview-\(fixture.rawValue)",
                onShowPDF: {},
                // Drawings come back from the server as PDFs; here the chart stands in for them.
                renderDrawing: { _ in image },
                reviews: reviews
            )
            .navigationTitle(fixture.source.title)
            .summaryInlineNavigationTitle()
            .toolbar { PaperReaderTextToolbar() }
            // In a bar above the reader, as the preview pane shows it.
            .safeAreaInset(edge: .top, spacing: 0) {
                if reviews != nil {
                    HStack {
                        Spacer()
                        Button { showsReviews = true } label: { Label("Reviews", systemImage: "bubble.left.and.text.bubble.right") }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("paper-reviews-button")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
        .sheet(isPresented: $showsReviews) {
            if let reviews {
                PaperReviewsSheet(reviews: reviews, initialReview: opening == .diff ? FixturePaperReviewBackend.addressed : nil)
            }
        }
        .sheet(item: $composeQuote) { quote in
            if let reviews { PaperReviewComposeSheet(quote: quote.text, reviews: reviews, source: fixture.source) }
        }
        .task {
            guard reviews != nil else { return }
            await reviews?.load()
            // Presenting during the first appearance can be dropped: let the reader settle first.
            try? await Task.sleep(for: .milliseconds(400))
            switch opening {
            case .compose?: composeQuote = PaperReviewQuote(text: "No three positive integers satisfy")
            case .reviews?, .diff?: showsReviews = true
            case nil: break
            }
        }
    }

    /// A bar chart drawn the same way every time, standing in for the paper's images.
    private static func chartPNG() -> Data {
        let chart = HStack(alignment: .bottom, spacing: 14) {
            ForEach([0.35, 0.6, 0.45, 0.9, 0.7], id: \.self) { value in
                RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.2, green: 0.45, blue: 0.85)).frame(width: 36, height: 180 * value)
            }
        }
        .padding(24)
        .frame(width: 320, height: 240, alignment: .bottom)
        .background(Color(white: 0.96))
        let renderer = ImageRenderer(content: chart)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

enum PaperReaderFixture: String {
    case text
    case math
    case figures
    /// The text paper with reviews on two of its passages.
    case reviews

    var source: PaperSource {
        let image = PaperFile(path: "figures/chart.png", asset: PaperAsset(key: "chart", mimeType: "image/png", byteSize: 1))
        let bib = PaperFile(path: "refs.bib", content: Self.bibliography)
        switch self {
        case .text, .reviews: return PaperSource(title: self == .text ? "Reader: Text" : "Reader: Reviews", files: [PaperFile(path: "main.tex", content: Self.textLaTeX), bib], mainFile: "main.tex")
        case .math: return PaperSource(title: "Reader: Math", files: [PaperFile(path: "main.tex", content: Self.mathLaTeX)], mainFile: "main.tex")
        case .figures: return PaperSource(title: "Reader: Figures", files: [PaperFile(path: "main.tex", content: Self.figuresLaTeX), image], mainFile: "main.tex")
        }
    }

    private static let textLaTeX = #"""
        \documentclass{article}
        \title{Reading Papers \emph{Natively}}
        \author{Ada Lovelace \and Alan Turing}
        \date{1 May 2025}
        \begin{document}
        \maketitle
        \begin{abstract}
        We set a paper's LaTeX as native text, so it reflows and grows with the reader.
        \end{abstract}
        \section{Introduction}\label{sec:intro}
        Literate programming~\cite{knuth84} treats a program as \textbf{literature}.
        For $x \in \mathbb{R}$ we have $e^{i\pi} + 1 = 0$, see Section~\ref{sec:intro}.\footnote{A footnote.}
        \begin{itemize}
          \item Text that \textit{reflows}
          \item Formulas like $\frac{a}{b}$
          \begin{enumerate}
            \item numbered
            \item and nested
          \end{enumerate}
        \end{itemize}
        \begin{theorem}[Fermat]
        No three positive integers satisfy $a^n + b^n = c^n$ for $n > 2$.
        \end{theorem}
        \bibliographystyle{plain}
        \bibliography{refs}
        \end{document}
        """#

    private static let mathLaTeX = #"""
        \documentclass{article}
        \begin{document}
        \section{Formulas}
        The roots of $ax^2 + bx + c = 0$ are
        \begin{equation}\label{eq:roots}
          x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
        \end{equation}
        \begin{align}
          \sum_{i=1}^{n} i &= \frac{n(n+1)}{2} \\
          \int_0^\infty e^{-x^2}\,dx &= \frac{\sqrt{\pi}}{2} \nonumber \\
          \lim_{x \to 0} \frac{\sin x}{x} &= 1
        \end{align}
        \[
          A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}, \quad
          |x| = \begin{cases} x & x \geq 0 \\ -x & \text{otherwise} \end{cases}
        \]
        \[ \left( \frac{\hat{\theta} - \bar{x}}{\sqrt[3]{\vec{v}}} \right)^2 \leq \mathcal{L}(\theta) \]
        Equation~\eqref{eq:roots} is the quadratic formula.
        \end{document}
        """#

    private static let figuresLaTeX = #"""
        \documentclass{article}
        \begin{document}
        \section{Results}
        \begin{figure}[h]
          \centering
          \includegraphics[width=0.7\linewidth]{figures/chart}
          \caption{Growth over five years.}\label{fig:chart}
        \end{figure}
        \begin{table}[h]
          \centering
          \caption{Scores by model.}
          \begin{tabular}{lcr}
            \toprule
            Model & \multicolumn{2}{c}{Score} \\
            \midrule
            Base & 71.2 & \textbf{3.1} \\
            Ours & 84.5 & 2.4 \\
            \bottomrule
          \end{tabular}
        \end{table}
        \begin{figure}[h]
          \begin{tikzpicture}\draw (0,0) -- (1,1);\end{tikzpicture}
          \caption{A diagram.}
        \end{figure}
        \begin{lstlisting}[language=Python]
        def grow(x):
            return x * 1.1
        \end{lstlisting}
        \end{document}
        """#

    static let bibliography = #"""
        @article{knuth84,
          author = {Knuth, Donald E.},
          title = {Literate Programming},
          journal = {The Computer Journal},
          volume = {27}, number = {2}, pages = {97--111},
          year = 1984,
        }
        """#
}

/// Reviews kept in memory for the `reviews` fixture: one waiting for the agent and one it
/// finished, whose change (version 2 → 3) adds a definition of literate programming.
actor FixturePaperReviewBackend: PaperReviewBackend {
    static let waiting = PaperReview(
        id: "fixture-waiting", paperId: "fixture", file: "main.tex", quote: "Text that reflows",
        comment: "Give an example of text that reflows on a small screen.", status: .open, version: 2,
        createdAt: Date(timeIntervalSince1970: 1_791_540_000), updatedAt: Date(timeIntervalSince1970: 1_791_540_000)
    )
    static let addressed = PaperReview(
        id: "fixture-addressed", paperId: "fixture", file: "main.tex", quote: "treats a program as literature",
        comment: "Say what literate programming means before using the term.", status: .addressed, version: 2, addressedVersion: 3,
        agentNote: "Added Knuth's definition and a sentence on why it matters.",
        createdAt: Date(timeIntervalSince1970: 1_791_536_400), updatedAt: Date(timeIntervalSince1970: 1_791_538_200),
        addressedAt: Date(timeIntervalSince1970: 1_791_538_200)
    )

    private var reviews: [PaperReview]
    private let versions: [Int: PaperSource]

    init(source: PaperSource) {
        reviews = [Self.addressed, Self.waiting]
        var edited = source
        if let main = source.file(source.mainFile) {
            edited.write(source.mainFile, content: main.content.replacingOccurrences(
                of: #"Literate programming~\cite{knuth84} treats a program as \textbf{literature}."#,
                with: #"""
                Literate programming~\cite{knuth84} treats a program as \textbf{literature}: an essay written for people,
                from which the compiler's input is extracted. Reading it first as prose makes its design visible.
                """#
            ))
        }
        versions = [2: source, 3: edited]
    }

    func list() async throws -> [PaperReview] { reviews }

    func create(_ draft: PaperReviewDraft) async throws -> PaperReview {
        let review = PaperReview(id: UUID().uuidString, paperId: "fixture", file: draft.file, quote: draft.quote, comment: draft.comment, version: 3)
        reviews.append(review)
        return review
    }

    func update(id: String, status: PaperReviewStatus?, comment: String?) async throws -> PaperReview {
        guard let index = reviews.firstIndex(where: { $0.id == id }) else { throw PaperProjectError("No such review.") }
        if let status { reviews[index].status = status }
        if let comment { reviews[index].comment = comment }
        if status == .resolved { reviews[index].resolvedAt = .now }
        return reviews[index]
    }

    func delete(id: String) async throws { reviews.removeAll { $0.id == id } }

    func source(version: Int) async throws -> PaperSource {
        guard let source = versions[version] else { throw PaperProjectError("No version \(version).") }
        return source
    }
}
#endif
