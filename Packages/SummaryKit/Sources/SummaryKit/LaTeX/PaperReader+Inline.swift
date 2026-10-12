import Foundation

extension PaperReaderParser {
    /// Paragraph content from other text: a command's argument, a caption, a table cell.
    func parseInline(_ text: String, style: PaperTextStyle? = nil) -> [PaperSpan] {
        parsing(text) {
            styleStack = [style ?? self.style]
            var spans: [PaperSpan] = []
            while !isAtEnd { inlineStep(&spans) }
            return spans
        }
    }

    /// One piece of paragraph content: text, a formula, a command or a brace.
    func inlineStep(_ spans: inout [PaperSpan]) {
        let c = chars[pos]
        switch c {
        case "\\":
            inlineCommand(&spans)
        case "$":
            pos += 1
            spans.append(math(readUntil("$")))
        case "{":
            pos += 1
            styleStack.append(style)
        case "}":
            pos += 1
            if styleStack.count > 1 { styleStack.removeLast() }
        case "~":
            pos += 1
            append("\u{00A0}", to: &spans)
        case "-":
            var dashes = 0
            while !isAtEnd, chars[pos] == "-", dashes < 3 { dashes += 1; pos += 1 }
            append(dashes == 3 ? "—" : dashes == 2 ? "–" : "-", to: &spans)
        case "`", "'":
            pos += 1
            let doubled = !isAtEnd && chars[pos] == c
            if doubled { pos += 1 }
            append(c == "`" ? (doubled ? "“" : "‘") : (doubled ? "”" : "’"), to: &spans)
        case "&":
            pos += 1
            append(" ", to: &spans)
        default:
            if c.isWhitespace {
                skipSpaces()
                append(" ", to: &spans)
                return
            }
            let start = pos
            while !isAtEnd, !Self.specialCharacters.contains(chars[pos]), !chars[pos].isWhitespace { pos += 1 }
            append(String(chars[start..<pos]), to: &spans)
        }
    }

    private static let specialCharacters: Set<Character> = ["\\", "$", "{", "}", "~", "-", "`", "'", "&"]

    func append(_ text: String, to spans: inout [PaperSpan]) {
        guard !text.isEmpty else { return }
        if let last = spans.last, last.style == style, case .text(let previous) = last.kind {
            if text == " ", previous.last == " " { return }
            spans[spans.count - 1].kind = .text(previous + text)
        } else {
            spans.append(.text(text, style: style))
        }
    }

    func math(_ raw: String) -> PaperSpan {
        PaperSpan(.math(PaperMath.parse(raw), source: raw.trimmingCharacters(in: .whitespacesAndNewlines)), style: style)
    }

    // MARK: Commands

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func inlineCommand(_ spans: inout [PaperSpan]) {
        pos += 1
        guard !isAtEnd else { return }
        let first = chars[pos]
        guard first.isLetter else {
            pos += 1
            symbolCommand(first, into: &spans)
            return
        }
        let name = readLetters()
        _ = readStar()
        if let text = Self.textSymbols[name] {
            append(text, to: &spans)
            skipCommandSpace()
            return
        }
        if let change = Self.styleArguments[name] {
            let raw = readGroup() ?? readArgument()
            spans += parseInline(raw, style: change(style))
            return
        }
        if let change = Self.styleDeclarations[name] {
            style = change(style)
            skipCommandSpace()
            return
        }
        if let form = Self.citationForms[name] {
            citation(form, into: &spans)
            return
        }
        if let form = Self.referenceForms[name] {
            for key in (readGroup() ?? "").split(separator: ",") {
                spans.append(PaperSpan(.reference(key.trimmingCharacters(in: .whitespaces), form: form), style: style))
            }
            return
        }
        if Self.accents[name] != nil, !isAtEnd, chars[pos] == "{" || chars[pos].isWhitespace {
            append(Self.accented(readArgument(), name), to: &spans)
            return
        }
        if readSetting(name) { return }
        if let count = Self.skippedArguments[name] {
            _ = readOptional()
            for _ in 0..<count { _ = readGroup() }
            _ = readOptional()
            if name == "hspace" { append(" ", to: &spans) }
            return
        }
        switch name {
        case "label": label((readGroup() ?? "").trimmingCharacters(in: .whitespaces))
        case "footnote", "thanks":
            _ = readOptional()
            spans.append(PaperSpan(.footnote(addFootnote(readGroup() ?? ""))))
        case "footnotetext":
            _ = readOptional()
            addFootnote(readGroup() ?? "")
        case "nocite":
            for key in (readGroup() ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if key == "*" { citesEverything = true } else { cite(key) }
            }
        case "url", "path":
            let url = readGroup() ?? ""
            spans.append(PaperSpan(.link(url, url: url), style: style))
        case "href":
            let url = readGroup() ?? ""
            let label = parseInline(readGroup() ?? url).plainText
            spans.append(PaperSpan(.link(label, url: url), style: style))
        case "verb", "lstinline":
            _ = readOptional()
            guard !isAtEnd else { return }
            let delimiter = chars[pos]
            pos += 1
            let code = readUntil(delimiter == "{" ? "}" : String(delimiter))
            spans.append(.text(code, style: style.union(.monospace)))
        case "begin":
            let environment = readGroup() ?? ""
            let body = readEnvironment(environment)
            if environment == "math" { spans.append(math(body)) } else { spans += parseInline(body) }
        case "newline", "linebreak", "break", "cr":
            _ = readOptional()
            spans.append(PaperSpan(.lineBreak))
            skipCommandSpace()
        case "today":
            append(Self.today, to: &spans)
            skipCommandSpace()
        case "texorpdfstring":
            let shown = readGroup() ?? ""
            _ = readGroup()
            spans += parseInline(shown)
        case "textcolor", "colorbox", "fcolorbox":
            _ = readOptional()
            _ = readGroup()
            if name == "fcolorbox" { _ = readGroup() }
            spans += parseInline(readGroup() ?? "")
        case "makebox", "framebox", "parbox", "raisebox", "resizebox", "scalebox", "rotatebox":
            _ = readOptional()
            _ = readOptional()
            if ["parbox", "raisebox", "scalebox", "rotatebox"].contains(name) { _ = readGroup() }
            if name == "resizebox" { _ = readGroup(); _ = readGroup() }
            spans += parseInline(readGroup() ?? "")
        case "includegraphics":
            _ = readOptional()
            _ = readGroup()
        case "caption":
            _ = readOptional()
            spans += parseInline(readGroup() ?? "")
        case "and":
            append(", ", to: &spans)
        default:
            if !isAtEnd, chars[pos] == "[" { _ = readOptional() }
            skipCommandSpace()
        }
    }

    /// `\&`, `\\`, `\'e`, `\(`…
    private func symbolCommand(_ c: Character, into spans: inout [PaperSpan]) {
        switch c {
        case "\\":
            _ = readStar()
            _ = readOptional()
            spans.append(PaperSpan(.lineBreak))
        case "(":
            spans.append(math(readUntil("\\)")))
        case "[":
            spans.append(math(readUntil("\\]")))
        case " ", "\n", "\t":
            append(" ", to: &spans)
        case ",":
            append("\u{2009}", to: &spans)
        case ";", ":", "!", "/", "@", "-", ">", "<":
            break
        default:
            if Self.accents[String(c)] != nil {
                append(Self.accented(readArgument(), String(c)), to: &spans)
            } else {
                append(String(c), to: &spans)
            }
        }
    }

    /// TeX drops the space after a command word: `\LaTeX is` reads "LaTeXis", so papers write
    /// `\LaTeX{}`; the empty group is skipped here too.
    private func skipCommandSpace() {
        if hasPrefix("{}") { pos += 2; return }
        while !isAtEnd, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
    }

    // MARK: Citations and footnotes

    private func citation(_ form: PaperCitationForm, into spans: inout [PaperSpan]) {
        let first = readOptional()
        let second = readOptional()
        let keys = (readGroup() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        keys.forEach(cite)
        let note = (second ?? first)?.trimmingCharacters(in: .whitespaces)
        spans.append(PaperSpan(.citation(keys, form: form, note: note?.isEmpty == false ? note : nil), style: style))
    }

    func cite(_ key: String) {
        if !citationOrder.contains(key) { citationOrder.append(key) }
    }

    /// Adds a footnote and returns its number.
    @discardableResult
    private func addFootnote(_ raw: String) -> Int {
        // Reserve the number first: footnotes inside this one come after it.
        document.footnotes.append([])
        let number = document.footnotes.count
        document.footnotes[number - 1] = Self.trimmed(parseInline(raw, style: []))
        return number
    }

    // MARK: Command tables

    private static let citationForms: [String: PaperCitationForm] = [
        "cite": .numeric, "citep": .numeric, "parencite": .numeric, "autocite": .numeric, "Cite": .numeric, "citealp": .numeric,
        "supercite": .numeric, "footcite": .numeric, "cites": .numeric, "Autocite": .numeric, "Parencite": .numeric,
        "citet": .textual, "textcite": .textual, "citealt": .textual, "Citet": .textual, "Textcite": .textual,
        "citeauthor": .author, "Citeauthor": .author, "citeyear": .year, "citeyearpar": .year, "citedate": .year,
    ]

    private static let referenceForms: [String: PaperReferenceForm] = [
        "ref": .number, "eqref": .equation, "autoref": .named, "Autoref": .named, "cref": .named, "Cref": .named,
        "vref": .named, "Vref": .named, "nameref": .number, "pageref": .page, "subref": .number,
    ]

    private static let styleArguments: [String: @Sendable (PaperTextStyle) -> PaperTextStyle] = [
        "textbf": { $0.union(.bold) }, "textit": { $0.union(.italic) }, "textsl": { $0.union(.italic) },
        "emph": { $0.symmetricDifference(.italic) }, "texttt": { $0.union(.monospace) }, "textsc": { $0.union(.smallCaps) },
        "underline": { $0.union(.underline) }, "uline": { $0.union(.underline) }, "sout": { $0.union(.strikethrough) },
        "st": { $0.union(.strikethrough) }, "textsf": { $0.union(.sansSerif) }, "textup": { $0.subtracting(.italic) },
        "textmd": { $0.subtracting(.bold) }, "textrm": { $0.subtracting([.sansSerif, .monospace]) }, "textnormal": { _ in [] },
        "mbox": { $0 }, "fbox": { $0 }, "hbox": { $0 }, "text": { $0 }, "hl": { $0 }, "textsuperscript": { $0 },
        "textsubscript": { $0 }, "enquote": { $0 }, "foreignlanguage": { $0 }, "noindent": { $0 },
    ]

    private static let styleDeclarations: [String: @Sendable (PaperTextStyle) -> PaperTextStyle] = [
        "bfseries": { $0.union(.bold) }, "bf": { $0.union(.bold) }, "itshape": { $0.union(.italic) }, "it": { $0.union(.italic) },
        "slshape": { $0.union(.italic) }, "sl": { $0.union(.italic) }, "em": { $0.symmetricDifference(.italic) },
        "ttfamily": { $0.union(.monospace) }, "tt": { $0.union(.monospace) }, "scshape": { $0.union(.smallCaps) },
        "sc": { $0.union(.smallCaps) }, "sffamily": { $0.union(.sansSerif) }, "sf": { $0.union(.sansSerif) },
        "upshape": { $0.subtracting(.italic) }, "mdseries": { $0.subtracting(.bold) }, "normalfont": { _ in [] },
        "rmfamily": { $0.subtracting([.sansSerif, .monospace]) }, "rm": { $0.subtracting([.sansSerif, .monospace]) },
    ]

    /// Commands whose arguments print nothing: how many braced groups to skip.
    private static let skippedArguments: [String: Int] = [
        "usepackage": 1, "documentclass": 1, "pagestyle": 1, "thispagestyle": 1, "pagenumbering": 1, "setlength": 2,
        "addtolength": 2, "setcounter": 2, "addtocounter": 2, "stepcounter": 1, "refstepcounter": 1, "definecolor": 3,
        "color": 1, "pagecolor": 1, "hspace": 1, "vspace": 1, "hypersetup": 1, "lstset": 1, "captionsetup": 1,
        "pgfplotsset": 1, "usetikzlibrary": 1, "tikzset": 1, "numberwithin": 2, "geometry": 1, "newcounter": 1,
        "bibliographystyle": 1, "phantom": 1, "hphantom": 1, "vphantom": 1, "addcontentsline": 3, "markboth": 2,
        "markright": 1, "setstretch": 1, "linespread": 1, "fontsize": 2, "enlargethispage": 1, "addvspace": 1,
        "selectlanguage": 1, "sisetup": 1, "setmainfont": 1, "setsansfont": 1, "setmonofont": 1, "setCJKmainfont": 1,
        "fancyhead": 1, "fancyfoot": 1, "lhead": 1, "chead": 1, "rhead": 1, "lfoot": 1, "cfoot": 1, "rfoot": 1,
        "rule": 2,
    ]

    private static let textSymbols: [String: String] = [
        "LaTeX": "LaTeX", "TeX": "TeX", "LaTeXe": "LaTeX2ε", "BibTeX": "BibTeX", "XeLaTeX": "XeLaTeX", "LuaLaTeX": "LuaLaTeX",
        "ldots": "…", "dots": "…", "textellipsis": "…", "textbackslash": "\\", "textasciitilde": "~", "textasciicircum": "^",
        "textbar": "|", "textless": "<", "textgreater": ">", "textendash": "–", "textemdash": "—", "textquoteleft": "‘",
        "textquoteright": "’", "textquotedblleft": "“", "textquotedblright": "”", "textbullet": "•", "textdegree": "°",
        "degree": "°", "copyright": "©", "textcopyright": "©", "textregistered": "®", "texttrademark": "™", "S": "§", "P": "¶",
        "dag": "†", "ddag": "‡", "pounds": "£", "euro": "€", "texteuro": "€", "ss": "ß", "ae": "æ", "AE": "Æ", "oe": "œ",
        "OE": "Œ", "o": "ø", "O": "Ø", "aa": "å", "AA": "Å", "l": "ł", "L": "Ł", "i": "ı", "j": "ȷ", "quad": "\u{2003}",
        "qquad": "\u{2003}\u{2003}", "enspace": "\u{2002}", "thinspace": "\u{2009}", "nobreakspace": "\u{00A0}",
        "textunderscore": "_", "guillemotleft": "«", "guillemotright": "»", "textperthousand": "‰", "checkmark": "✓",
        "textpm": "±", "texttimes": "×", "textmu": "µ", "textsection": "§", "hfill": " ", "space": " ", "slash": "/",
        "textrightarrow": "→", "textleftarrow": "←", "textdagger": "†", "textdaggerdbl": "‡", "textparagraph": "¶",
        "textonehalf": "½", "textquotesingle": "'", "textasteriskcentered": "∗", "textvisiblespace": "␣",
    ]

    /// Combining marks for `\'e`, `\"o`, `\c{c}`.
    private static let accents: [String: String] = [
        "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "\"": "\u{0308}", "~": "\u{0303}", "=": "\u{0304}", ".": "\u{0307}",
        "c": "\u{0327}", "v": "\u{030C}", "u": "\u{0306}", "H": "\u{030B}", "k": "\u{0328}", "r": "\u{030A}", "d": "\u{0323}",
        "b": "\u{0331}",
    ]

    static func accented(_ argument: String, _ accent: String) -> String {
        let base = switch argument.trimmingCharacters(in: .whitespaces) {
        case "\\i": "ı"
        case "\\j": "ȷ"
        case let other: other
        }
        guard let mark = accents[accent], !base.isEmpty else { return base }
        return (base + mark).precomposedStringWithCanonicalMapping
    }
}
