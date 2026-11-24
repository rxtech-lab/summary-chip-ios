#if DEBUG
import Foundation
import SummaryKit

/// The fixture paper's LaTeX: text, math, a theorem, a figure, a table and a TikZ drawing.
nonisolated enum LikesPreviewPaper {
    /// `edited` is version 3, with the agent's change for the finished review.
    static func source(edited: Bool) -> PaperSource {
        let main = edited ? mainLaTeX.replacingOccurrences(of: introduction, with: editedIntroduction) : mainLaTeX
        return PaperSource(title: "Reading Papers Natively", files: [
            PaperFile(path: "main.tex", content: main),
            PaperFile(path: "refs.bib", content: bibliography),
            PaperFile(path: "figures/chart.png", asset: PaperAsset(key: "chart", mimeType: "image/png", byteSize: 1)),
        ], mainFile: "main.tex")
    }

    private static let introduction = #"Literate programming~\cite{knuth84} treats a program as \textbf{literature}."#

    private static let editedIntroduction = #"""
        Literate programming~\cite{knuth84} treats a program as \textbf{literature}: an essay written for people,
        from which the compiler's input is extracted. Reading it first as prose makes its design visible.
        """#

    private static let mainLaTeX = #"""
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
        \end{itemize}
        \begin{theorem}[Fermat]
        No three positive integers satisfy $a^n + b^n = c^n$ for $n > 2$.
        \end{theorem}
        \section{Results}
        The roots of $ax^2 + bx + c = 0$ are
        \begin{equation}\label{eq:roots}
          x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
        \end{equation}
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
        \bibliographystyle{plain}
        \bibliography{refs}
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
