import Foundation
import Testing
@testable import SummaryKit

@Suite struct LaTeXSyntaxTests {
    private func spans(_ text: String, _ language: LaTeXLanguage = .tex) -> [(LaTeXToken.Kind, String)] {
        LaTeXSyntax.tokens(in: text, language: language).map { ($0.kind, (text as NSString).substring(with: $0.range)) }
    }

    private func has(_ kind: LaTeXToken.Kind, _ text: String, in found: [(LaTeXToken.Kind, String)]) -> Bool {
        found.contains { $0.0 == kind && $0.1 == text }
    }

    @Test func picksTheLanguageFromTheExtension() {
        #expect(LaTeXLanguage(fileExtension: "TEX") == .tex)
        #expect(LaTeXLanguage(fileExtension: "sty") == .tex)
        #expect(LaTeXLanguage(fileExtension: "bib") == .bibtex)
        #expect(LaTeXLanguage(fileExtension: "csv") == .plain)
    }

    @Test func highlightsTeX() {
        let found = spans(#"\section{Intro} see \ref{fig:a} and $x^2$ % 50\% done"# + "\n" + #"\begin{figure}\[ a \]"#)
        #expect(has(.command, "\\section", in: found))
        #expect(has(.heading, "Intro", in: found))
        #expect(has(.argument, "fig:a", in: found))
        #expect(has(.math, "$x^2$", in: found))
        #expect(has(.comment, #"% 50\% done"#, in: found))
        #expect(has(.environment, "figure", in: found))
        #expect(has(.math, #"\[ a \]"#, in: found))
        #expect(has(.delimiter, "{", in: found))
    }

    @Test func anEscapedPercentIsNoComment() {
        #expect(!spans(#"100\% sure"#).contains { $0.0 == .comment })
        #expect(!spans(#"costs \$5 and \$6"#).contains { $0.0 == .math })
    }

    @Test func highlightsBibTeX() {
        let found = spans("@article{knuth84,\n  title = {Literate Programming},\n}", .bibtex)
        #expect(has(.entryType, "@article", in: found))
        #expect(has(.argument, "knuth84", in: found))
        #expect(has(.field, "title", in: found))
    }

    @Test func plainFilesHaveNoTokens() {
        #expect(LaTeXSyntax.tokens(in: "a,b,\\c", language: .plain).isEmpty)
    }
}

@Suite struct LaTeXCompletionTests {
    private let symbols = LaTeXSymbols(source: PaperSource(
        title: "T",
        files: [
            PaperFile(path: "main.tex", content: #"\newcommand{\R}{\mathbb{R}}\def\eps{\varepsilon}\newtheorem{claim}{Claim}\label{eq:one}"#),
            PaperFile(path: "sections/intro.tex", content: #"\label{sec:intro}"#),
            PaperFile(path: "refs.bib", content: "@string{x = y}\n@article{knuth84,\n  title = {Literate {P}rogramming},\n}\n@book{lamport94, title=\"LaTeX\"}"),
            PaperFile(path: "figs/plot.png", asset: PaperAsset(key: "uploads/plot.png", mimeType: "image/png", byteSize: 100)),
        ],
        mainFile: "main.tex"
    ))

    /// The context at the `|` in `text`, with `|` removed.
    private func context(_ marked: String) -> (String, LaTeXCompletionContext?) {
        let cursor = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        return (text, LaTeXCompletion.context(in: text, at: cursor))
    }

    private func apply(_ edit: LaTeXCompletionEdit, to text: String) -> String {
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.text) as NSString
        return result.replacingCharacters(in: edit.selection, with: "|")
    }

    private func complete(_ marked: String, with label: String) throws -> String {
        let (text, found) = context(marked)
        let context = try #require(found)
        let suggestion = try #require(LaTeXCompletion.suggestions(for: context, in: text, symbols: symbols, limit: 500).first { $0.label == label })
        return apply(LaTeXCompletion.edit(applying: suggestion, kind: context.kind, replacing: context.range, in: text), to: text)
    }

    @Test func scansThePaper() {
        #expect(symbols.commands == ["R", "eps"])
        #expect(symbols.environments == ["claim"])
        #expect(symbols.labels == ["eq:one", "sec:intro"])
        #expect(symbols.citations.map(\.key) == ["knuth84", "lamport94"])
        #expect(symbols.citations.first?.title == "Literate Programming")
        #expect(symbols.texFiles == ["sections/intro"])
        #expect(symbols.graphics == ["figs/plot.png"])
        #expect(symbols.bibFiles == ["refs.bib"])
    }

    @Test func findsTheContext() {
        #expect(context(#"a \sec|"#).1 == LaTeXCompletionContext(kind: .command, range: NSRange(location: 2, length: 4), prefix: "sec"))
        #expect(context(#"a \|"#).1?.kind == .command)
        #expect(context(#"a \\sec|"#).1 == nil)
        #expect(context(#"\begin{fig|"#).1?.prefix == "fig")
        #expect(context(#"\cite[p.~3]{knuth84, lam|"#).1 == LaTeXCompletionContext(kind: .citation, range: NSRange(location: 21, length: 3), prefix: "lam"))
        #expect(context(#"\eqref{|}"#).1?.kind == .reference)
        #expect(context(#"\addbibresource{|"#).1?.kind == .bibliography(withExtension: true))
        #expect(context(#"\textbf{bold|"#).1 == nil)
        #expect(context(#"\input{a, b|"#).1 == nil)
        #expect(context("plain text|").1 == nil)
    }

    @Test func ranksCommands() throws {
        let (text, found) = context(#"\Del|"#)
        let labels = LaTeXCompletion.suggestions(for: try #require(found), in: text, symbols: symbols).map(\.label)
        #expect(labels.first == "\\Delta")
        #expect(labels.contains("\\delta"))
        let (own, ownContext) = context(#"$\e|"#)
        #expect(LaTeXCompletion.suggestions(for: try #require(ownContext), in: own, symbols: symbols).first?.label == "\\eps")
    }

    @Test func completesCommands() throws {
        #expect(try complete(#"\textb|"#, with: "\\textbf") == #"\textbf{|}"#)
        #expect(try complete(#"\alp|ha x"#, with: "\\alpha") == #"\alpha| x"#)
        #expect(try complete(#"\fr|"#, with: "\\frac") == #"\frac{|}{}"#)
    }

    @Test func completesEnvironments() throws {
        #expect(try complete("  \\begin{it|}", with: "itemize") == "  \\begin{itemize}\n    \\item |\n  \\end{itemize}")
        #expect(try complete("\\begin{fig|}\n\\end{figure}", with: "figure") == "\\begin{figure}|\n\\end{figure}")
        let (text, found) = context("\\begin{figure}\\begin{center}\\end{center}\\end{|")
        #expect(LaTeXCompletion.suggestions(for: try #require(found), in: text, symbols: symbols).first?.label == "figure")
    }

    @Test func completesArguments() throws {
        #expect(try complete(#"\cite{kn|}"#, with: "knuth84") == #"\cite{knuth84}|"#)
        #expect(try complete(#"\cite{kn|, lamport94}"#, with: "knuth84") == #"\cite{knuth84|, lamport94}"#)
        #expect(try complete(#"\ref{sec:|"#, with: "sec:intro") == #"\ref{sec:intro}|"#)
        #expect(try complete(#"\input{sec|"#, with: "sections/intro") == #"\input{sections/intro}|"#)
        #expect(try complete(#"\bibliography{r|"#, with: "refs") == #"\bibliography{refs}|"#)
        #expect(try complete(#"\usepackage{amss|"#, with: "amssymb") == #"\usepackage{amssymb}|"#)
    }
}

@Suite struct LaTeXEditorSupportTests {
    private let symbols = LaTeXSymbols(source: PaperSource(
        title: "T",
        files: [
            PaperFile(path: "main.tex", content: "\\documentclass{article}\n\\newcommand{\\R}{\\mathbb{R}}\n\\section{Intro}\\label{sec:intro}"),
            PaperFile(path: "refs.bib", content: "@article{knuth84,\n  author = {Knuth, Donald E.},\n  title = {Literate Programming},\n  year = 1984,\n}"),
        ],
        mainFile: "main.tex"
    ))

    /// The info at the `|` in `marked`, with `|` removed.
    private func info(_ marked: String) -> LaTeXHoverInfo? {
        let index = (marked as NSString).range(of: "|").location
        return LaTeXInfo.info(in: marked.replacingOccurrences(of: "|", with: ""), at: index, symbols: symbols)
    }

    @Test func indexesLines() {
        let index = LaTeXLineIndex("ab\ncd\n\nef")
        #expect(index.lineCount == 4)
        #expect(index.line(at: 0) == 1 && index.line(at: 2) == 1 && index.line(at: 3) == 2 && index.line(at: 6) == 3 && index.line(at: 9) == 4)
        #expect(index.range(ofLine: 2) == NSRange(location: 3, length: 2))
        #expect(index.range(ofLine: 4) == NSRange(location: 7, length: 2))
        #expect(index.range(ofLine: 5) == nil)
    }

    @Test func recordsWhereThingsAreDefined() {
        #expect(symbols.commandDefinitions["R"] == LaTeXSymbols.Location(file: "main.tex", line: 2, text: "\\newcommand{\\R}{\\mathbb{R}}"))
        #expect(symbols.labelDefinitions["sec:intro"]?.line == 3)
        #expect(symbols.citation("knuth84")?.year == "1984")
    }

    @Test func describesCompletions() throws {
        let text = "\\fra"
        let context = try #require(LaTeXCompletion.context(in: text, at: 4))
        let frac = try #require(LaTeXCompletion.suggestions(for: context, in: text, symbols: symbols).first { $0.label == "\\frac" })
        #expect(frac.detail?.contains("fraction") == true)
        let cite = "\\cite{kn"
        let citeContext = try #require(LaTeXCompletion.context(in: cite, at: 8))
        #expect(LaTeXCompletion.suggestions(for: citeContext, in: cite, symbols: symbols).first?.detail == "Knuth (1984) — Literate Programming")
    }

    @Test func describesWhatIsHovered() throws {
        let frac = try #require(info("$\\fr|ac{1}{2}$"))
        #expect(frac.title == "\\frac{…}{…}" && frac.range == NSRange(location: 1, length: 5))
        #expect(info("\\|R")?.source == "\\newcommand{\\R}{\\mathbb{R}}")
        #expect(info("\\begin{ite|mize}")?.title == "itemize")
        #expect(info("\\cite{a, knu|th84}")?.detail == "Knuth (1984) — Literate Programming")
        #expect(info("\\cite{miss|ing}")?.isProblem == true)
        #expect(info("\\ref{sec:in|tro}")?.detail == "Labelled in main.tex:3")
        #expect(info("\\usepackage{ams|math}")?.title == "amsmath")
        #expect(info("plain wo|rd") == nil)
        #expect(info("\\\\ no|t") == nil)
    }

    @Test func matchesBrackets() {
        let text = "\\frac{a}{\\{b\\}} % {"
        #expect(LaTeXBrackets.match(in: text, at: 6) == LaTeXBracketMatch(bracket: NSRange(location: 5, length: 1), partner: NSRange(location: 7, length: 1)))
        #expect(LaTeXBrackets.match(in: text, at: 15)?.partner == NSRange(location: 8, length: 1))
        #expect(LaTeXBrackets.match(in: text, at: 20) == nil)
        #expect(LaTeXBrackets.match(in: "{ % }\n}", at: 7)?.partner == NSRange(location: 0, length: 1))
        #expect(LaTeXBrackets.match(in: "a{b", at: 2)?.partner == nil)
        #expect(LaTeXBrackets.match(in: "abc", at: 1) == nil)
    }

    @Test func pairsBraces() {
        let open = LaTeXBrackets.autoPair(in: "\\textbf", replacing: NSRange(location: 7, length: 0), with: "{")
        #expect(open == LaTeXCompletionEdit(range: NSRange(location: 7, length: 0), text: "{}", selection: NSRange(location: 8, length: 0)))
        #expect(LaTeXBrackets.autoPair(in: "\\", replacing: NSRange(location: 1, length: 0), with: "{") == nil)
        #expect(LaTeXBrackets.autoPair(in: "word", replacing: NSRange(location: 0, length: 0), with: "{") == nil)
        #expect(LaTeXBrackets.autoPair(in: "{}", replacing: NSRange(location: 1, length: 0), with: "}")?.selection == NSRange(location: 2, length: 0))
        #expect(LaTeXBrackets.autoPair(in: "{}", replacing: NSRange(location: 0, length: 1), with: "")?.range == NSRange(location: 0, length: 2))
        #expect(LaTeXBrackets.autoPair(in: "a", replacing: NSRange(location: 1, length: 0), with: "b") == nil)
    }
}
