import Foundation

extension PaperReaderParser {
    /// The blocks of `\begin{name}…\end{name}`, at its body.
    // swiftlint:disable:next cyclomatic_complexity
    func environment(_ name: String, alignment: PaperAlignment) -> [PaperBlock] {
        let base = name.trimmingCharacters(in: ["*"])
        switch base {
        case "center", "flushleft", "flushright", "raggedright", "raggedleft":
            let aligned: PaperAlignment = base == "center" ? .center : base == "flushright" || base == "raggedleft" ? .trailing : .leading
            return nested(readEnvironment(name), alignment: aligned)
        case "minipage":
            _ = readOptional(); _ = readOptional(); _ = readOptional()
            _ = readGroup()
            return nested(readEnvironment(name), alignment: alignment)
        case "multicols":
            _ = readGroup()
            return nested(readEnvironment(name), alignment: alignment)
        case "abstract":
            return [PaperBlock(id: newID(), kind: .abstract(nested(readEnvironment(name), alignment: .leading)))]
        case "itemize", "enumerate", "description", "compactitem", "compactenum", "compactdesc", "inparaenum", "asparaenum", "asparaitem":
            return [list(name)]
        case "equation", "align", "gather", "multline", "eqnarray", "displaymath", "flalign", "alignat", "dmath":
            if base == "alignat" { _ = readGroup() }
            return [equation(readEnvironment(name), environment: name)]
        case "figure", "table", "wrapfigure", "wraptable", "SCfigure", "SCtable", "sidewaysfigure", "sidewaystable", "marginfigure",
             "margintable", "subfigure", "subtable", "figwindow":
            if base.hasPrefix("wrap") || base.hasPrefix("sub") { _ = readOptional(); _ = readGroup(); if base.hasPrefix("wrap") { _ = readGroup() } }
            _ = readOptional()
            return float(readEnvironment(name), environment: base)
        case "tabular", "tabularx", "longtable", "tabulary", "xltabular", "supertabular", "tblr":
            return tableBlocks(readEnvironment(name), environment: name)
        case "tikzpicture", "pgfpicture", "circuitikz", "forest", "tikzcd":
            _ = readEnvironment(name)
            return [PaperBlock(id: newID(), kind: .figure(PaperFigure(images: [], drawings: 1, caption: nil, number: nil, name: "Figure")))]
        case "quote", "quotation", "verse", "displayquote":
            return [PaperBlock(id: newID(), kind: .quote(nested(readEnvironment(name), alignment: .leading)))]
        case "verbatim", "Verbatim", "lstlisting", "minted", "alltt", "BVerbatim", "LVerbatim":
            return [code(name)]
        case "comment":
            _ = readEnvironment(name)
            return []
        case "thebibliography":
            _ = readGroup()
            bibItems += Self.split(readEnvironment(name), at: "bibitem").map { item in
                parsing(item.content) {
                    let key = (readGroup() ?? "").trimmingCharacters(in: .whitespaces)
                    return (key: key, raw: String(chars[pos...]))
                }
            }
            return [PaperBlock(id: newID(), kind: .bibliography)]
        default:
            if base == "proof" || theoremKinds[base] != nil || Self.theoremTitles[base] != nil {
                return [theorem(base, environment: name)]
            }
            return nested(readEnvironment(name), alignment: alignment)
        }
    }

    func nested(_ text: String, alignment: PaperAlignment) -> [PaperBlock] {
        parsing(text) { parseBlocks(alignment: alignment) }
    }

    // MARK: Lists

    private func list(_ name: String) -> PaperBlock {
        _ = readOptional()
        let body = readEnvironment(name)
        let style: PaperList.Style = name.contains("enum") ? .numbered : name.contains("desc") ? .description : .bullet
        let id = newID()
        let depth = listDepth
        listDepth += 1
        defer { listDepth -= 1 }
        let items = Self.split(body, at: "item").enumerated().map { index, item in
            if style == .numbered {
                labelTarget = PaperLabel(kind: .item, number: String(index + 1), name: "Item", block: id)
            }
            return PaperList.Item(label: item.label.map { Self.trimmed(parseInline($0)) }, blocks: nested(item.content, alignment: .leading))
        }
        return PaperBlock(id: id, kind: .list(PaperList(style: style, depth: depth, items: items)))
    }

    /// The text after each top-level `\item` (or `\bibitem`), with its `[…]` label.
    static func split(_ body: String, at command: String) -> [(label: String?, content: String)] {
        let parser = PaperReaderParser(source: PaperSource(title: "", files: [], mainFile: ""))
        return parser.parsing(body) {
            var items: [(label: String?, content: String)] = []
            var current: (label: String?, start: Int)?
            var depth = 0
            while !parser.isAtEnd {
                let c = parser.chars[parser.pos]
                if c == "{" || c == "}" {
                    depth += c == "{" ? 1 : -1
                    parser.pos += 1
                    continue
                }
                guard c == "\\" else { parser.pos += 1; continue }
                if parser.hasCommand("begin") { depth += 1; parser.pos += 6; continue }
                if parser.hasCommand("end") { depth -= 1; parser.pos += 4; continue }
                if depth == 0, parser.hasCommand(command) {
                    if let current { items.append((current.label, String(parser.chars[current.start..<parser.pos]))) }
                    parser.pos += command.count + 1
                    let label = parser.readOptional()
                    current = (label, parser.pos)
                    continue
                }
                parser.pos += 2
            }
            if let current { items.append((current.label, String(parser.chars[min(current.start, parser.chars.count)...]))) }
            return items
        }
    }

    // MARK: Equations

    func equation(_ raw: String, environment: String) -> PaperBlock {
        let id = newID()
        let base = environment.trimmingCharacters(in: ["*"])
        let numbered = !environment.hasSuffix("*") && base != "displaymath"
        let aligned = ["align", "eqnarray", "flalign", "alignat"].contains(base)
        let perRow = aligned || base == "gather"
        let lines = perRow || base == "multline" ? Self.splitTopLevel(raw, at: "\\\\") : [raw]
        var rows: [PaperEquation.Row] = []
        for (index, line) in lines.enumerated() {
            var text = line
            let tag = Self.extract("tag", from: &text).last
            let labels = Self.extract("label", from: &text)
            let suppressed = text.contains("\\nonumber") || text.contains("\\notag")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tag != nil else { continue }
            var number = tag.map { $0.trimmingCharacters(in: .whitespaces) }
            if number == nil, numbered, !suppressed, perRow || index == lines.count - 1 {
                equationCount += 1
                number = floatNumber(equationCount)
            }
            for key in labels {
                document.labels[key.trimmingCharacters(in: .whitespaces)] = PaperLabel(kind: .equation, number: number ?? "", name: "Equation", block: id)
            }
            let cells = aligned ? Self.splitTopLevel(text, at: "&").map(PaperMath.parse) : [PaperMath.parse(text)]
            rows.append(PaperEquation.Row(cells: cells, number: number))
        }
        var source = raw
        _ = Self.extract("label", from: &source)
        return PaperBlock(id: id, kind: .equation(PaperEquation(rows: rows, isAligned: aligned, source: source.trimmingCharacters(in: .whitespacesAndNewlines))))
    }

    /// Splits at `separator` outside braces and nested environments.
    static func splitTopLevel(_ text: String, at separator: String) -> [String] {
        let chars = Array(text)
        let separatorChars = Array(separator)
        var parts: [String] = []
        var depth = 0
        var start = 0
        var index = 0
        func matches(_ word: String) -> Bool {
            let word = Array(word)
            guard index + word.count <= chars.count, Array(chars[index..<index + word.count]) == word else { return false }
            return index + word.count == chars.count || !chars[index + word.count].isLetter
        }
        while index < chars.count {
            let c = chars[index]
            if depth == 0, index + separatorChars.count <= chars.count, Array(chars[index..<index + separatorChars.count]) == separatorChars {
                parts.append(String(chars[start..<index]))
                index += separatorChars.count
                start = index
                continue
            }
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } else if c == "\\" {
                if matches("\\begin") { depth += 1 } else if matches("\\end") { depth -= 1 }
                index += 2
                continue
            }
            index += 1
        }
        parts.append(String(chars[start...]))
        return parts
    }

    /// Removes every `\name{…}` from `text` and returns the arguments.
    static func extract(_ name: String, from text: inout String) -> [String] {
        guard text.contains("\\" + name) else { return [] }
        let regex = try! NSRegularExpression(pattern: "\\\\" + name + #"\*?\s*\{([^{}]*)\}"#)
        let string = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: string.length))
        let values = matches.map { string.substring(with: $0.range(at: 1)) }
        text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: string.length), withTemplate: "")
        return values
    }

    // MARK: Theorems and code

    static let theoremTitles: [String: String] = [
        "theorem": "Theorem", "lemma": "Lemma", "proposition": "Proposition", "corollary": "Corollary", "definition": "Definition",
        "remark": "Remark", "example": "Example", "conjecture": "Conjecture", "claim": "Claim", "assumption": "Assumption",
        "note": "Note", "exercise": "Exercise", "problem": "Problem", "observation": "Observation", "fact": "Fact",
        "hypothesis": "Hypothesis", "notation": "Notation", "question": "Question", "solution": "Solution", "axiom": "Axiom",
        "property": "Property", "thm": "Theorem", "lem": "Lemma", "prop": "Proposition", "cor": "Corollary", "defn": "Definition",
        "dfn": "Definition", "rem": "Remark", "ex": "Example",
    ]

    private func theorem(_ base: String, environment name: String) -> PaperBlock {
        let note = readOptional()
        let body = readEnvironment(name)
        let id = newID()
        if base == "proof" {
            let title = note.map { Self.trimmed(parseInline($0)).plainText } ?? "Proof"
            return PaperBlock(id: id, kind: .theorem(PaperTheorem(name: title, number: nil, note: nil, blocks: nested(body, alignment: .leading), isProof: true)))
        }
        let kind = theoremKinds[base] ?? PaperTheoremKind(title: Self.theoremTitles[base] ?? base.capitalized, counter: base, numbered: true, within: nil)
        var number: String?
        if kind.numbered, !name.hasSuffix("*") {
            let prefix = kind.within.map(sectionPrefix) ?? ""
            let counter = kind.counter + "@" + prefix
            theoremCounts[counter, default: 0] += 1
            number = prefix + String(theoremCounts[counter] ?? 1)
        }
        labelTarget = PaperLabel(kind: .theorem, number: number ?? "", name: kind.title, block: id)
        let theorem = PaperTheorem(
            name: kind.title, number: number, note: note.map { Self.trimmed(parseInline($0)) },
            blocks: nested(body, alignment: .leading), isProof: false
        )
        return PaperBlock(id: id, kind: .theorem(theorem))
    }

    /// `2.` for theorems numbered within section 2.
    private func sectionPrefix(_ within: String) -> String {
        let depth = ["chapter": 0, "section": 1, "subsection": 2, "subsubsection": 3][within.trimmingCharacters(in: .whitespaces)] ?? 1
        let top = hasChapters ? 0 : 1
        guard depth >= top else { return "" }
        return (top...depth).map { String(sectionCounters[$0]) }.joined(separator: ".") + "."
    }

    private func code(_ name: String) -> PaperBlock {
        var language: String?
        if name == "minted" {
            _ = readOptional()
            language = readGroup()
        } else if name == "lstlisting" || name.hasSuffix("Verbatim") {
            let options = readOptional() ?? ""
            language = options.split(separator: ",").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("language") }
                .flatMap { $0.split(separator: "=").last }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " {}")) }
        }
        var body = readEnvironment(name)
        if body.hasPrefix("\n") { body.removeFirst() }
        while body.hasSuffix("\n") || body.hasSuffix(" ") { body.removeLast() }
        return PaperBlock(id: newID(), kind: .code(body, language: language))
    }
}
