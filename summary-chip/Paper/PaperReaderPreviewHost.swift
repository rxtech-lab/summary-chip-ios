#if DEBUG
import ImageIO
import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// The native paper reader on fixed LaTeX, for UI tests that compare its screenshots with
/// reference images: launch with `--preview-paper-reader` and `--reader-fixture text|math|figures`.
/// The text size starts at its default on every launch so the screenshots don't depend on the
/// last run.
struct PaperReaderPreviewHost: View {
    private let fixture: PaperReaderFixture
    private let image: Data

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let name = arguments.firstIndex(of: "--reader-fixture").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        fixture = name.flatMap(PaperReaderFixture.init(rawValue:)) ?? .text
        UserDefaults.standard.removeObject(forKey: PaperReaderSettings.fontSizeKey)
        UserDefaults.standard.removeObject(forKey: PaperReaderSettings.serifKey)
        image = Self.chartPNG()
    }

    var body: some View {
        let image = image
        NavigationStack {
            PaperReaderView(
                source: fixture.source,
                loadImage: { _ in image },
                imageScope: "preview-\(fixture.rawValue)",
                onShowPDF: {}
            )
            .navigationTitle(fixture.source.title)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .summaryTrailing) { PaperReaderTextControls() }
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

    var source: PaperSource {
        let image = PaperFile(path: "figures/chart.png", asset: PaperAsset(key: "chart", mimeType: "image/png", byteSize: 1))
        let bib = PaperFile(path: "refs.bib", content: Self.bibliography)
        switch self {
        case .text: return PaperSource(title: "Reader: Text", files: [PaperFile(path: "main.tex", content: Self.textLaTeX), bib], mainFile: "main.tex")
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

    private static let bibliography = #"""
        @article{knuth84,
          author = {Knuth, Donald E.},
          title = {Literate Programming},
          journal = {The Computer Journal},
          volume = {27}, number = {2}, pages = {97--111},
          year = 1984,
        }
        """#
}
#endif
