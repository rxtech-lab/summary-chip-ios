#if DEBUG
import SummaryKit
import SwiftUI

/// Exercises the paper editor (highlighting, completion, brackets, errors, hover) without a server
/// session: launch with `--preview-paper-editor`.
struct PaperEditorPreviewHost: View {
    @State private var text = Self.main

    private static let main = #"""
        \documentclass{article}
        \usepackage{amsmath,graphicx}
        \newcommand{\R}{\mathbb{R}}

        \begin{document}
        \section{Introduction}\label{sec:intro}
        Literate programming \cite{knuth84} treats a program as a work of literature.
        For $x \in \R$ we have \frac{1}{2} and see Section~\ref{sec:intro}. % a comment {
        \undefinedcommand{oops}

        \begin{equation}
          E = mc^2
        \end{equation}
        \end{document}
        """#

    private var source: PaperSource {
        PaperSource(title: "Preview", files: [
            PaperFile(path: "main.tex", content: text),
            PaperFile(path: "refs.bib", content: "@article{knuth84,\n  author = {Knuth, Donald E.},\n  title = {Literate Programming},\n  year = 1984,\n}"),
        ], mainFile: "main.tex")
    }

    var body: some View {
        NavigationStack {
            PaperSourceEditor(
                text: $text,
                fileID: "main.tex",
                language: .tex,
                isEditable: true,
                issues: [PaperEditorIssue(line: 9, message: "Undefined control sequence.")],
                symbols: { LaTeXSymbols(source: source) }
            )
            .navigationTitle("main.tex")
        }
    }
}
#endif
