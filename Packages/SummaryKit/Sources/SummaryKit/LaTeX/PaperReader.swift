import Foundation

/// Reads a paper's LaTeX into a document the app draws natively, without compiling it: the
/// main file with its `\input`s, the paper's own commands expanded, sections, figures, tables
/// and equations numbered, and the bibliography from its `.bib` files or `thebibliography`.
/// Anything it doesn't know shows as its text, so a paper always reads, if not always as LaTeX
/// would set it.
public enum PaperReader {
    public static func read(_ source: PaperSource) -> PaperReaderDocument {
        PaperReaderParser(source: source).run()
    }
}

final class PaperReaderParser {
    let source: PaperSource
    var chars: [Character] = []
    var pos = 0
    var document = PaperReaderDocument()
    private var nextID = 0

    // Definitions and settings
    var macros: [String: PaperMacro] = [:]
    var theoremKinds: [String: PaperTheoremKind] = [:]
    var hasChapters = false
    var graphicsPaths: [String] = [""]
    var titleRaw: String?
    var authorRaw: String?
    var dateRaw: String?
    var bibliographyStyle: String?
    var bibFiles: [String] = []
    var biblatexUnsorted = false
    var citesEverything = false
    var citationOrder: [String] = []
    var bibItems: [(key: String, raw: String)] = []

    // Counters
    /// Chapter, section, subsection, subsubsection.
    var sectionCounters = [0, 0, 0, 0]
    var isAppendix = false
    var figureCount = 0
    var tableCount = 0
    var equationCount = 0
    var theoremCounts: [String: Int] = [:]
    var headings: [PaperHeading] = []
    /// What a `\label` here names: the latest section, float, equation or item.
    var labelTarget: PaperLabel?
    var styleStack: [PaperTextStyle] = [[]]
    var listDepth = 0

    init(source: PaperSource) {
        self.source = source
    }

    func newID() -> Int {
        nextID += 1
        return nextID
    }

    var style: PaperTextStyle {
        get { styleStack.last ?? [] }
        set { styleStack[styleStack.count - 1] = newValue }
    }

    func run() -> PaperReaderDocument {
        let text = collectDefinitions(assemble())
        let (preamble, body) = Self.split(text)
        readPreamble(preamble)
        hasChapters = hasChapters || body.contains("\\chapter")
        chars = Array(expandMacros(body))
        pos = 0
        document.blocks = parseBlocks()
        finishBibliography()
        finishContents()
        return document
    }

    /// The preamble and the document body; a file without `\begin{document}` is all body.
    private static func split(_ text: String) -> (String, String) {
        guard let begin = text.range(of: "\\begin{document}") else { return ("", text) }
        let body = text[begin.upperBound...]
        let end = body.range(of: "\\end{document}")?.lowerBound ?? body.endIndex
        return (String(text[..<begin.lowerBound]), String(body[..<end]))
    }

    private func readPreamble(_ preamble: String) {
        chars = Array(preamble)
        pos = 0
        while !isAtEnd {
            guard chars[pos] == "\\" else { pos += 1; continue }
            pos += 1
            let name = readLetters()
            switch name {
            case "documentclass":
                _ = readOptional()
                let documentClass = readGroup() ?? ""
                hasChapters = ["report", "book", "memoir", "scrreprt", "scrbook"].contains(documentClass.trimmingCharacters(in: .whitespaces))
            case "usepackage":
                let options = readOptional() ?? ""
                if readGroup()?.contains("biblatex") == true, options.replacingOccurrences(of: " ", with: "").contains("sorting=none") {
                    biblatexUnsorted = true
                }
            default:
                readSetting(name)
            }
        }
    }

    /// Commands that set up the paper rather than print anything, in the preamble or the body.
    /// Returns false for any other command.
    @discardableResult
    func readSetting(_ name: String) -> Bool {
        switch name {
        case "title": _ = readOptional(); titleRaw = readGroup()
        case "author": _ = readOptional(); authorRaw = readGroup()
        case "date": dateRaw = readGroup()
        case "bibliographystyle": bibliographyStyle = readGroup()
        case "addbibresource": _ = readOptional(); if let file = readGroup() { bibFiles.append(file) }
        case "graphicspath":
            guard let raw = readGroup() else { return true }
            let paths = raw.split(separator: "}").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "{ \n")) }.filter { !$0.isEmpty }
            graphicsPaths = [""] + paths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        default: return false
        }
        return true
    }

    // MARK: Characters

    var isAtEnd: Bool { pos >= chars.count }

    func hasPrefix(_ prefix: String) -> Bool {
        var index = pos
        for c in prefix {
            guard index < chars.count, chars[index] == c else { return false }
            index += 1
        }
        return true
    }

    /// `\name` here, not followed by more letters.
    func hasCommand(_ name: String) -> Bool {
        guard hasPrefix("\\" + name) else { return false }
        let end = pos + name.count + 1
        return end >= chars.count || !chars[end].isLetter
    }

    func readLetters() -> String {
        var name = ""
        while !isAtEnd, chars[pos].isLetter || chars[pos] == "@" {
            name.append(chars[pos])
            pos += 1
        }
        return name
    }

    func readStar() -> Bool {
        guard !isAtEnd, chars[pos] == "*" else { return false }
        pos += 1
        return true
    }

    /// Skips spaces and at most one line break: a blank line ends a paragraph.
    func skipSpaces() {
        var newlines = 0
        while !isAtEnd, chars[pos].isWhitespace {
            if chars[pos].isNewline {
                if newlines == 1 { return }
                newlines += 1
            }
            pos += 1
        }
    }

    /// A braced group's characters as written, or nil when the next thing isn't a group.
    func readGroup() -> String? {
        let saved = pos
        skipSpaces()
        guard !isAtEnd, chars[pos] == "{" else { pos = saved; return nil }
        pos += 1
        return readBalanced(until: "}")
    }

    /// `[…]`, or nil when there's none.
    func readOptional() -> String? {
        let saved = pos
        skipSpaces()
        guard !isAtEnd, chars[pos] == "[" else { pos = saved; return nil }
        pos += 1
        return readBalanced(until: "]")
    }

    /// Up to the closing character at brace depth 0, skipping escaped characters.
    private func readBalanced(until close: Character) -> String {
        var depth = 0
        let start = pos
        while !isAtEnd {
            let c = chars[pos]
            if c == "\\" { pos += 2; continue }
            if c == "{" { depth += 1 } else if c == "}" {
                if depth == 0 && close == "}" { break }
                depth -= 1
            } else if c == close, depth == 0 { break }
            pos += 1
        }
        let end = min(pos, chars.count)
        if !isAtEnd { pos += 1 }
        return String(chars[start..<end])
    }

    /// A group, or else the next single character or command.
    func readArgument() -> String {
        if let group = readGroup() { return group }
        skipSpaces()
        guard !isAtEnd else { return "" }
        let start = pos
        pos += 1
        if chars[start] == "\\" {
            if !isAtEnd, chars[pos].isLetter { _ = readLetters() } else if !isAtEnd { pos += 1 }
        }
        return String(chars[start..<pos])
    }

    /// Everything up to `end` (consumed), as written.
    func readUntil(_ end: String) -> String {
        let start = pos
        while !isAtEnd, !hasPrefix(end) {
            pos += chars[pos] == "\\" && end != "\\" ? 2 : 1
        }
        let raw = String(chars[start..<min(pos, chars.count)])
        pos = min(pos + end.count, chars.count)
        return raw
    }

    /// An environment's body up to its matching `\end{name}` (consumed), nested ones included.
    func readEnvironment(_ name: String) -> String {
        let begin = "\\begin{\(name)}"
        let end = "\\end{\(name)}"
        let start = pos
        var depth = 0
        while !isAtEnd {
            if hasPrefix(end) {
                if depth == 0 {
                    let body = String(chars[start..<pos])
                    pos += end.count
                    return body
                }
                depth -= 1
                pos += end.count
                continue
            }
            if hasPrefix(begin) { depth += 1; pos += begin.count; continue }
            pos += chars[pos] == "\\" ? 2 : 1
        }
        return String(chars[start..<min(pos, chars.count)])
    }

    /// Runs `body` over other text with the same document state, then returns to this text.
    func parsing<T>(_ text: String, _ body: () -> T) -> T {
        let saved = (chars, pos, styleStack)
        chars = Array(text)
        pos = 0
        defer { (chars, pos, styleStack) = saved }
        return body()
    }

    /// At a blank line: consumes it and the space after.
    private func consumeBlankLine() -> Bool {
        var index = pos
        var newlines = 0
        while index < chars.count, chars[index].isWhitespace {
            if chars[index].isNewline { newlines += 1 }
            index += 1
        }
        guard newlines >= 2 else { return false }
        pos = index
        return true
    }

    // MARK: Blocks

    private static let blockCommands: Set<String> = [
        "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph", "begin", "end", "par",
        "maketitle", "tableofcontents", "bibliography", "printbibliography", "appendix", "includegraphics", "item",
    ]

    /// Blocks until the end of the text.
    func parseBlocks(alignment: PaperAlignment = .leading) -> [PaperBlock] {
        var blocks: [PaperBlock] = []
        var paragraph: [PaperSpan] = []
        func flush() {
            let spans = Self.trimmed(paragraph)
            paragraph = []
            guard !spans.isEmpty else { return }
            blocks.append(PaperBlock(id: newID(), kind: .paragraph(spans, alignment)))
        }
        while !isAtEnd {
            if chars[pos].isWhitespace, consumeBlankLine() { flush(); continue }
            if hasPrefix("\\[") || hasPrefix("$$") {
                flush()
                let display = hasPrefix("$$")
                pos += 2
                blocks.append(equation(readUntil(display ? "$$" : "\\]"), environment: "equation*"))
                continue
            }
            if chars[pos] == "\\", pos + 1 < chars.count, chars[pos + 1].isLetter {
                let start = pos
                pos += 1
                let name = readLetters()
                if name == "begin", let environment = readGroup(), environment != "math" {
                    flush()
                    blocks += self.environment(environment.trimmingCharacters(in: .whitespaces), alignment: alignment)
                    continue
                }
                pos = start
                if Self.blockCommands.contains(name), name != "begin" {
                    flush()
                    pos += name.count + 1
                    blocks += blockCommand(name)
                    continue
                }
            }
            inlineStep(&paragraph)
        }
        flush()
        return blocks
    }

    private func blockCommand(_ name: String) -> [PaperBlock] {
        switch name {
        case "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph":
            return [heading(name)]
        case "end", "par", "item":
            if name == "end" { _ = readGroup() }
            return []
        case "maketitle":
            return titleBlock().map { [$0] } ?? []
        case "tableofcontents":
            return [PaperBlock(id: newID(), kind: .contents([]))]
        case "bibliography", "printbibliography":
            if name == "bibliography", let files = readGroup() {
                bibFiles += files.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                _ = readOptional()
            }
            return [PaperBlock(id: newID(), kind: .bibliography)]
        case "appendix":
            isAppendix = true
            sectionCounters[hasChapters ? 0 : 1] = 0
            return []
        case "includegraphics":
            let image = includedImage()
            return [PaperBlock(id: newID(), kind: .figure(PaperFigure(images: [image], drawings: 0, caption: nil, number: nil, name: "Figure")))]
        default:
            return []
        }
    }

    private func titleBlock() -> PaperBlock? {
        guard let titleRaw else { return nil }
        let authors = (authorRaw ?? "").components(separatedBy: "\\and")
            .map { parseInline($0.replacingOccurrences(of: "\\\\", with: ", ")) }
            .map(Self.trimmed)
            .filter { !$0.isEmpty }
        let date = dateRaw.map { Self.trimmed(parseInline($0)) } ?? [.text(Self.today)]
        let title = PaperTitle(title: Self.trimmed(parseInline(titleRaw)), authors: authors, date: date.isEmpty ? nil : date)
        return PaperBlock(id: newID(), kind: .title(title))
    }

    static var today: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: Date())
    }

    // MARK: Headings

    private func heading(_ name: String) -> PaperBlock {
        let starred = readStar()
        _ = readOptional()
        let title = Self.trimmed(parseInline(readGroup() ?? ""))
        let id = newID()
        let depth: Int? = switch name {
        case "chapter": 0
        case "section": 1
        case "subsection": 2
        case "subsubsection": 3
        default: nil
        }
        let top = hasChapters ? 0 : 1
        let level = switch name {
        case "part": 1
        case "paragraph", "subparagraph": 4
        default: min(max((depth ?? 0) - top + 1, 1), 4)
        }
        var number: String?
        if let depth, !starred, depth >= top {
            sectionCounters[depth] += 1
            for deeper in (depth + 1)..<sectionCounters.count { sectionCounters[deeper] = 0 }
            if depth == 0 {
                figureCount = 0
                tableCount = 0
                equationCount = 0
            }
            number = (top...depth).map { index in
                index == top && isAppendix ? PaperList.letter(sectionCounters[index]).uppercased() : String(sectionCounters[index])
            }.joined(separator: ".")
        }
        let heading = PaperHeading(level: level, number: number, title: title, block: id)
        if number != nil { headings.append(heading) }
        labelTarget = PaperLabel(kind: .section, number: number ?? "", name: name == "chapter" ? "Chapter" : isAppendix && depth == top ? "Appendix" : "Section", block: id)
        return PaperBlock(id: id, kind: .heading(heading))
    }

    /// `3` in an article, `2.3` in a report: floats and equations count within chapters.
    func floatNumber(_ count: Int) -> String {
        guard hasChapters, sectionCounters[0] > 0 else { return String(count) }
        let chapter = isAppendix ? PaperList.letter(sectionCounters[0]).uppercased() : String(sectionCounters[0])
        return "\(chapter).\(count)"
    }

    func label(_ key: String) {
        guard let labelTarget, !key.isEmpty else { return }
        document.labels[key] = labelTarget
    }

    private func finishContents() {
        let numbered = headings
        document.blocks = document.blocks.map { block in
            guard case .contents = block.kind else { return block }
            return PaperBlock(id: block.id, kind: .contents(numbered))
        }
    }

    /// Without the space at either end.
    static func trimmed(_ spans: [PaperSpan]) -> [PaperSpan] {
        var spans = spans
        while let first = spans.first, case .text(let text) = first.kind {
            let rest = String(text.drop { $0.isWhitespace })
            if rest.isEmpty { spans.removeFirst() } else { spans[0].kind = .text(rest); break }
        }
        while let last = spans.last {
            if case .lineBreak = last.kind { spans.removeLast(); continue }
            guard case .text(let text) = last.kind else { break }
            let rest = String(text.reversed().drop { $0.isWhitespace }.reversed())
            if rest.isEmpty { spans.removeLast() } else { spans[spans.count - 1].kind = .text(rest); break }
        }
        return spans
    }
}
