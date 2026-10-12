import Foundation
import Testing
@testable import SummaryKit

@Suite struct PaperMathTests {
    private func text(_ latex: String) -> String { PaperMath.runs(PaperMath.parse(latex)).map(\.text).joined() }

    @Test func parsesFractionsAndScripts() {
        #expect(PaperMath.parse(#"\frac{a}{b}"#) == [.fraction([.symbol("a", .italic)], [.symbol("b", .italic)], line: true)])
        #expect(PaperMath.parse("x^2_i") == [.scripts(base: [.symbol("x", .italic)], superscript: [.symbol("2", .upright)], subscript: [.symbol("i", .italic)])])
        #expect(PaperMath.parse("{}^{14}C").first == .scripts(base: [], superscript: [.symbol("14", .upright)], subscript: nil))
    }

    @Test func classifiesSymbols() {
        #expect(PaperMath.parse(#"\alpha \Gamma"#) == [.symbol("α", .italic), .symbol("Γ", .upright)])
        #expect(PaperMath.parse("a - b") == [.symbol("a", .italic), .operation("−", .binary), .symbol("b", .italic)])
        #expect(PaperMath.parse("-b").first == .symbol("−", .upright))
        #expect(PaperMath.parse(#"x \leq y"#)[1] == .operation("≤", .relation))
        #expect(PaperMath.parse(#"\mathbb{R}^n"#).first == .scripts(base: [.symbol("ℝ", .upright)], superscript: [.symbol("n", .italic)], subscript: nil))
        #expect(PaperMath.parse(#"\mathcal{L}"#) == [.symbol("ℒ", .upright)])
        guard case .scripts(let base, _, _)? = PaperMath.parse(#"\sum_{i=1}^n"#).first else {
            Issue.record("expected scripts")
            return
        }
        #expect(base == [.largeOperator("∑", limits: true)])
    }

    @Test func parsesDelimitersAndEnvironments() {
        guard case .fenced("(", let inner, ")")? = PaperMath.parse(#"\left( \frac{1}{2} \right)"#).first else {
            Issue.record("expected a fenced group")
            return
        }
        #expect(inner.count == 1)
        guard case .fenced("(", let matrix, ")")? = PaperMath.parse(#"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#).first,
              case .table(let rows, .matrix)? = matrix.first else {
            Issue.record("expected a matrix")
            return
        }
        #expect(rows.count == 2)
        #expect(rows[1].count == 2)
        #expect(rows[1][1] == [.symbol("d", .italic)])
    }

    @Test func flattensInlineFormulas() {
        #expect(text(#"\frac{a+b}{c}"#) == "(a\u{2005}+\u{2005}b)/c")
        #expect(text(#"\sqrt{x}"#) == "√x")
        #expect(text(#"\sin x"#) == "sin\u{2009}x")
        #expect(text(#"\hat{x}"#) == "x\u{0302}")
        #expect(text(#"\text{if } x"#) == "if x")
        let runs = PaperMath.runs(PaperMath.parse("e^{i}"))
        #expect(runs.count == 2)
        #expect(runs[1].scale < 1)
        #expect(runs[1].baseline > 0)
    }
}

@Suite struct PaperReaderTests {
    private func read(_ main: String, files: [PaperFile] = []) -> PaperReaderDocument {
        PaperReader.read(PaperSource(title: "T", files: [PaperFile(path: "main.tex", content: main)] + files, mainFile: "main.tex"))
    }

    private func headings(_ document: PaperReaderDocument) -> [String] {
        document.blocks.compactMap {
            if case .heading(let heading) = $0.kind { return [heading.number, heading.title.plainText].compactMap { $0 }.joined(separator: " ") }
            return nil
        }
    }

    private func paragraphs(_ blocks: [PaperBlock]) -> [[PaperSpan]] {
        blocks.compactMap { if case .paragraph(let spans, _) = $0.kind { spans } else { nil } }
    }

    @Test func readsTheTitleSectionsAndParagraphs() {
        let document = read(#"""
        \documentclass{article}
        \title{A \emph{Study}}
        \author{Ada Lovelace \and Alan Turing}
        \date{2024}
        \begin{document}
        \maketitle
        \section{Introduction}
        Hello -- ``world''. % a comment
        Same paragraph.

        \subsection*{Background}
        \subsection{Method}
        \section{End}
        \end{document}
        """#)
        guard case .title(let title) = document.blocks.first?.kind else {
            Issue.record("expected the title first")
            return
        }
        #expect(title.title.plainText == "A Study")
        #expect(title.title.contains { $0.style.contains(.italic) })
        #expect(title.authors.map(\.plainText) == ["Ada Lovelace", "Alan Turing"])
        #expect(title.date?.plainText == "2024")
        #expect(headings(document) == ["1 Introduction", "Background", "1.1 Method", "2 End"])
        #expect(paragraphs(document.blocks).map(\.plainText) == ["Hello – “world”. Same paragraph."])
    }

    @Test func numbersChaptersInReports() {
        let document = read(#"\documentclass{report}\begin{document}\chapter{One}\section{A}\begin{equation}x\end{equation}\chapter{Two}\section{B}\appendix\chapter{Extra}\end{document}"#)
        #expect(headings(document) == ["1 One", "1.1 A", "2 Two", "2.1 B", "A Extra"])
        let numbers = document.blocks.compactMap { if case .equation(let equation) = $0.kind { equation.rows.first?.number } else { nil } }
        #expect(numbers == ["1.1"])
    }

    @Test func inlinesInputsAndExpandsMacros() {
        let document = read(
            #"\newcommand{\R}{\mathbb{R}}\newcommand{\pair}[2]{(#1, #2)}\begin{document}\input{sections/intro}\end{document}"#,
            files: [PaperFile(path: "sections/intro.tex", content: #"Let $x \in \R$ and \pair{a}{b}."#)]
        )
        let spans = paragraphs(document.blocks).first ?? []
        #expect(spans.plainText == #"Let x \in \mathbb{R} and (a, b)."#)
        guard case .math(let nodes, _)? = spans.first(where: { if case .math = $0.kind { true } else { false } })?.kind else {
            Issue.record("expected a formula")
            return
        }
        #expect(nodes.last == .symbol("ℝ", .upright))
    }

    @Test func resolvesLabelsAndReferences() {
        let document = read(#"""
        \begin{document}
        \section{Intro}\label{sec:intro}
        See \ref{sec:intro}, \eqref{eq:e} and \autoref{fig:a}.
        \begin{align}
        a &= b \label{eq:first} \\
        c &= d \nonumber \\
        e &= f \label{eq:e}
        \end{align}
        \begin{figure}[h]
        \centering
        \includegraphics[width=0.5\linewidth]{plot}
        \caption{A plot.}\label{fig:a}
        \end{figure}
        \end{document}
        """#, files: [PaperFile(path: "plot.png", asset: PaperAsset(key: "k", mimeType: "image/png", byteSize: 1))])
        #expect(document.referenceText("sec:intro", form: .number) == "1")
        #expect(document.referenceText("eq:e", form: .equation) == "(2)")
        #expect(document.referenceText("eq:first", form: .number) == "1")
        #expect(document.referenceText("fig:a", form: .named) == "Figure 1")
        #expect(document.referenceText("missing", form: .number) == "??")
        let equation = document.blocks.compactMap { if case .equation(let equation) = $0.kind { equation } else { nil } }.first
        #expect(equation?.isAligned == true)
        #expect(equation?.rows.map(\.number) == ["1", nil, "2"])
        #expect(equation?.rows.first?.cells.count == 2)
        let figure = document.blocks.compactMap { if case .figure(let figure) = $0.kind { figure } else { nil } }.first
        #expect(figure?.images.first?.path == "plot.png")
        #expect(figure?.images.first?.width == 0.5)
        #expect(figure?.caption?.plainText == "A plot.")
        #expect(figure?.number == "1")
    }

    @Test func readsListsAndTheorems() {
        let document = read(#"""
        \newtheorem{thm}{Theorem}[section]
        \begin{document}
        \section{S}
        \begin{enumerate}
        \item First
        \item Second
          \begin{itemize}\item Inner\end{itemize}
        \end{enumerate}
        \begin{description}\item[Term] Meaning\end{description}
        \begin{thm}[Main]\label{thm:main} True.\end{thm}
        \begin{proof} Obvious. \end{proof}
        \end{document}
        """#)
        let lists = document.blocks.compactMap { if case .list(let list) = $0.kind { list } else { nil } }
        #expect(lists.count == 2)
        #expect(lists[0].style == .numbered)
        #expect(lists[0].items.count == 2)
        #expect(lists[0].marker(1) == "2.")
        guard case .list(let inner)? = lists[0].items[1].blocks.last?.kind else {
            Issue.record("expected a nested list")
            return
        }
        #expect(inner.style == .bullet)
        #expect(inner.depth == 1)
        #expect(lists[1].items.first?.label?.plainText == "Term")
        let theorems = document.blocks.compactMap { if case .theorem(let theorem) = $0.kind { theorem } else { nil } }
        #expect(theorems.map(\.name) == ["Theorem", "Proof"])
        #expect(theorems.first?.number == "1.1")
        #expect(theorems.first?.note?.plainText == "Main")
        #expect(document.referenceText("thm:main", form: .named) == "Theorem 1.1")
    }

    @Test func readsTables() {
        let document = read(#"""
        \begin{document}
        \begin{table}
        \caption{Results}\label{tab:r}
        \begin{tabular}{l|cr}
        \toprule
        Name & \multicolumn{2}{c}{Score} \\
        \midrule
        A & 1 & \textbf{2} \\
        B & 3 & 4 \\
        \bottomrule
        \end{tabular}
        \end{table}
        \end{document}
        """#)
        guard case .table(let table)? = document.blocks.first?.kind else {
            Issue.record("expected a table")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.rows.count == 3)
        #expect(table.headerRows == 1)
        #expect(table.rows[0][1].columns == 2)
        #expect(table.rows[1][2].content.first?.style.contains(.bold) == true)
        #expect(table.number == "1")
        #expect(document.referenceText("tab:r", form: .named) == "Table 1")
    }

    @Test func numbersCitationsFromTheBibFile() {
        let bib = PaperFile(path: "refs.bib", content: #"""
        @string{aw = "Addison-Wesley"}
        @book{knuth, author = {Knuth, Donald E.}, title = {The {\TeX}book}, publisher = aw, year = 1984}
        @article{lamport, author = "Leslie Lamport and others", title = {LaTeX}, journal = {J}, year = {1986}}
        @misc{unused, title = {Unused}}
        """#)
        let body = #"\begin{document}See \citet{lamport} and \cite[p.~3]{knuth,lamport}.\bibliography{refs}\end{document}"#
        let sorted = read(#"\bibliographystyle{plain}"# + body, files: [bib])
        #expect(sorted.bibliography.map(\.key) == ["knuth", "lamport"])
        #expect(sorted.citationText(["knuth", "lamport"], form: .numeric, note: "p.~3") == "[1, 2, p.~3]")
        #expect(sorted.citationText(["lamport"], form: .textual, note: nil) == "Lamport et al. [2]")
        #expect(sorted.bibliography.first?.text.plainText == "Donald E. Knuth. The TeXbook. Addison-Wesley, 1984.")
        let unsorted = read(#"\bibliographystyle{unsrt}"# + body, files: [bib])
        #expect(unsorted.bibliography.map(\.key) == ["lamport", "knuth"])
        #expect(unsorted.blocks.contains { $0.kind == .bibliography })
    }

    @Test func readsThebibliographyFootnotesAndCode() {
        let document = read(#"""
        \begin{document}
        Text\footnote{A note.} cites \cite{a}.
        \begin{verbatim}
        x = 1 % not a comment
        \end{verbatim}
        \begin{tikzpicture}\draw (0,0) -- (1,1);\end{tikzpicture}
        \begin{thebibliography}{9}
        \bibitem{a} A. Author. \emph{Title}.
        \end{thebibliography}
        \end{document}
        """#)
        #expect(document.footnotes.map(\.plainText) == ["A note."])
        #expect(document.citationNumbers["a"] == 1)
        #expect(document.bibliography.first?.text.plainText == "A. Author. Title.")
        #expect(document.blocks.contains { $0.kind == .code("x = 1 % not a comment", language: nil) })
        #expect(document.blocks.contains { if case .figure(let figure) = $0.kind { figure.drawings == 1 } else { false } })
    }

    @Test func readsAPaperWithoutAPreamble() {
        let document = read(#"Just \textbf{text} with \'el\`eve and \LaTeX{} here."#)
        #expect(paragraphs(document.blocks).first?.plainText == "Just text with élève and LaTeX here.")
    }
}
