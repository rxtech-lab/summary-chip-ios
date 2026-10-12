import Foundation

/// A formula from LaTeX math, parsed for drawing natively: the reader lays display formulas out
/// as nested views and flattens inline ones into styled text (`PaperMath.runs`).
public indirect enum MathNode: Sendable, Hashable {
    /// A letter, number or other ordinary symbol.
    case symbol(String, MathFont)
    /// `+`, `=`, `,`: spaced by their class.
    case operation(String, MathSpacing)
    /// `∑`, `∫`, `lim`: in display formulas `limits` puts the scripts above and below.
    case largeOperator(String, limits: Bool)
    /// Upright words: `\text{…}`, `sin`.
    case text(String)
    /// Horizontal space in em.
    case space(Double)
    case fraction([MathNode], [MathNode], line: Bool)
    case scripts(base: [MathNode], superscript: [MathNode]?, subscript: [MathNode]?)
    case radical([MathNode], index: [MathNode]?)
    case accent([MathNode], MathAccent)
    /// `\left( … \right)` and matrices: delimiters that grow with their contents; empty for none.
    case fenced(String, [MathNode], String)
    /// `matrix`, `cases`, `aligned`: rows of cells.
    case table([[[MathNode]]], MathTableStyle)
}

public enum MathFont: Sendable, Hashable { case italic, upright, bold, boldItalic }

public enum MathSpacing: Sendable, Hashable { case binary, relation, punctuation }

public enum MathAccent: Sendable, Hashable {
    case hat, tilde, bar, vector, dot, doubleDot, underline

    /// The combining mark inline formulas put on a single letter.
    public var combining: String {
        switch self {
        case .hat: "\u{0302}"
        case .tilde: "\u{0303}"
        case .bar: "\u{0305}"
        case .vector: "\u{20D7}"
        case .dot: "\u{0307}"
        case .doubleDot: "\u{0308}"
        case .underline: "\u{0332}"
        }
    }
}

public enum MathTableStyle: Sendable, Hashable {
    /// Centered columns.
    case matrix
    /// `aligned`/`align`: columns alternate right and left around `&`.
    case aligned
    /// `cases`: left-aligned columns with room between them.
    case cases
}

public enum PaperMath {
    /// Parses LaTeX math (without its `$` delimiters). Unknown commands show as their name.
    public static func parse(_ latex: String) -> [MathNode] {
        var parser = MathParser(Array(latex))
        var nodes: [MathNode] = []
        while !parser.isAtEnd {
            nodes += parser.parseList()
            parser.skipStray()
        }
        return nodes
    }
}

/// Recursive descent over the characters of a formula.
struct MathParser {
    struct Stops: OptionSet {
        let rawValue: Int
        /// `&`, `\\` and `\end` close a table cell.
        static let cell = Stops(rawValue: 1)
        /// `\right` closes a `\left`.
        static let right = Stops(rawValue: 2)
        /// `]` closes an optional argument.
        static let bracket = Stops(rawValue: 4)
    }

    private let chars: [Character]
    private var pos = 0
    /// `\limits`/`\nolimits` after an operator.
    private var pendingLimits: Bool?
    /// A function name like `sin` was just read; space it from what follows.
    private var afterFunction = false

    init(_ chars: [Character]) { self.chars = chars }

    var isAtEnd: Bool { pos >= chars.count }

    /// Steps over a `}` or `]` that closes nothing.
    mutating func skipStray() {
        if !isAtEnd { pos += 1 }
    }

    // MARK: Lists

    mutating func parseList(_ stops: Stops = []) -> [MathNode] {
        var atoms: [[MathNode]] = []
        while true {
            skipSpaces()
            guard !isAtEnd, !isStop(stops) else { break }
            let c = chars[pos]
            if c == "^" || c == "_" {
                pos += 1
                attach(argument(), superscript: c == "^", to: &atoms)
                continue
            }
            if c == "'" {
                var primes = ""
                while !isAtEnd, chars[pos] == "'" { primes += "′"; pos += 1 }
                attach([.symbol(primes, .upright)], superscript: true, to: &atoms)
                continue
            }
            let wasFunction = afterFunction
            afterFunction = false
            guard let atom = nextAtom(previous: atoms.last) else {
                afterFunction = wasFunction
                if let limits = pendingLimits, let last = atoms.last, case .largeOperator(let name, _)? = last.first, last.count == 1 {
                    atoms[atoms.count - 1] = [.largeOperator(name, limits: limits)]
                }
                pendingLimits = nil
                continue
            }
            if wasFunction, !Self.startsWithOpening(atom) { atoms.append([.space(0.17)]) }
            atoms.append(atom)
        }
        return atoms.flatMap { $0 }
    }

    private func isStop(_ stops: Stops) -> Bool {
        let c = chars[pos]
        if c == "}" { return true }
        if stops.contains(.bracket), c == "]" { return true }
        if stops.contains(.cell) {
            if c == "&" || hasPrefix("\\\\") || hasCommand("end") || hasCommand("cr") { return true }
        }
        return stops.contains(.right) && hasCommand("right")
    }

    private static func startsWithOpening(_ atom: [MathNode]) -> Bool {
        switch atom.first {
        case .symbol(let s, _)?: ["(", "["].contains(s)
        case .fenced?: true
        default: false
        }
    }

    private func attach(_ script: [MathNode], superscript: Bool, to atoms: inout [[MathNode]]) {
        if let last = atoms.last, last.count == 1, case .scripts(let base, let sup, let sub) = last[0],
           superscript ? sup == nil : sub == nil {
            atoms[atoms.count - 1] = [.scripts(base: base, superscript: superscript ? script : sup, subscript: superscript ? sub : script)]
            return
        }
        let base = atoms.popLast() ?? []
        atoms.append([.scripts(base: base, superscript: superscript ? script : nil, subscript: superscript ? nil : script)])
    }

    // MARK: Atoms

    /// One atom, or nil for something that draws nothing (`\label`, `\displaystyle`).
    private mutating func nextAtom(previous: [MathNode]?) -> [MathNode]? {
        let c = chars[pos]
        if c == "{" {
            pos += 1
            let inner = parseList()
            if !isAtEnd, chars[pos] == "}" { pos += 1 }
            return inner
        }
        if c == "\\" { return command(previous: previous) }
        pos += 1
        if c.isLetter { return [.symbol(String(c), .italic)] }
        if c.isNumber {
            var number = String(c)
            while !isAtEnd, chars[pos].isNumber || (chars[pos] == "." && pos + 1 < chars.count && chars[pos + 1].isNumber) {
                number.append(chars[pos])
                pos += 1
            }
            return [.symbol(number, .upright)]
        }
        switch c {
        case "+": return Self.isUnary(previous) ? [.symbol("+", .upright)] : [.operation("+", .binary)]
        case "-": return Self.isUnary(previous) ? [.symbol("−", .upright)] : [.operation("−", .binary)]
        case "*": return [.operation("∗", .binary)]
        case "=", "<", ">", ":": return [.operation(String(c), .relation)]
        case ",", ";": return [.operation(String(c), .punctuation)]
        case "~": return [.space(0.33)]
        case "&", "$", "#": return nil
        default: return [.symbol(String(c), .upright)]
        }
    }

    private static func isUnary(_ previous: [MathNode]?) -> Bool {
        guard let last = previous?.last else { return true }
        switch last {
        case .operation, .largeOperator: return true
        case .symbol(let s, _): return ["(", "[", "{", "⟨"].contains(s)
        default: return false
        }
    }

    /// A command, at its backslash.
    private mutating func command(previous: [MathNode]?) -> [MathNode]? {
        pos += 1
        guard !isAtEnd else { return nil }
        let first = chars[pos]
        guard first.isLetter else {
            pos += 1
            return Self.escaped(first)
        }
        var name = ""
        while !isAtEnd, chars[pos].isLetter { name.append(chars[pos]); pos += 1 }
        var starred = false
        if !isAtEnd, chars[pos] == "*" { starred = true; pos += 1 }
        if let symbol = MathSymbols.node(for: name) { return [symbol] }
        if MathSymbols.functions.contains(name) {
            afterFunction = true
            return [.text(name)]
        }
        if let name = MathSymbols.limitFunctions[name] { return [.largeOperator(name, limits: true)] }
        return structure(name, starred: starred, previous: previous)
    }

    private static func escaped(_ c: Character) -> [MathNode]? {
        switch c {
        case ",": [.space(0.17)]
        case ":", ">": [.space(0.22)]
        case ";": [.space(0.28)]
        case "!": [.space(-0.17)]
        case " ": [.space(0.33)]
        case "|": [.symbol("‖", .upright)]
        case "\\": nil
        default: [.symbol(String(c), .upright)]
        }
    }

    private mutating func structure(_ name: String, starred: Bool, previous: [MathNode]?) -> [MathNode]? {
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let numerator = argument()
            return [.fraction(numerator, argument(), line: true)]
        case "binom", "dbinom", "tbinom":
            let top = argument()
            return [.fenced("(", [.fraction(top, argument(), line: false)], ")")]
        case "sqrt":
            let index = optionalArgument()
            return [.radical(argument(), index: index)]
        case "hat", "widehat": return [.accent(argument(), .hat)]
        case "tilde", "widetilde": return [.accent(argument(), .tilde)]
        case "bar", "overline": return [.accent(argument(), .bar)]
        case "vec", "overrightarrow", "overleftrightarrow": return [.accent(argument(), .vector)]
        case "dot": return [.accent(argument(), .dot)]
        case "ddot": return [.accent(argument(), .doubleDot)]
        case "underline": return [.accent(argument(), .underline)]
        case "mathbb", "Bbb", "mathds": return MathSymbols.restyle(argument(), alphabet: .doubleStruck)
        case "mathcal", "mathscr": return MathSymbols.restyle(argument(), alphabet: .script)
        case "mathfrak": return MathSymbols.restyle(argument(), alphabet: .fraktur)
        case "mathbf": return MathSymbols.restyle(argument(), font: .bold)
        case "boldsymbol", "bm", "pmb": return MathSymbols.restyle(argument(), font: .boldItalic)
        case "mathrm", "mathup", "mathsf", "mathtt", "mathnormal": return MathSymbols.restyle(argument(), font: .upright)
        case "mathit": return MathSymbols.restyle(argument(), font: .italic)
        case "operatorname":
            let text = Self.plainText(rawGroup())
            if starred { return [.largeOperator(text, limits: true)] }
            afterFunction = true
            return [.text(text)]
        case "text", "textrm", "textnormal", "textup", "textit", "textbf", "textsf", "texttt", "mbox", "hbox", "emph", "intertext":
            return [.text(Self.plainText(rawGroup()))]
        default:
            return layout(name, previous: previous)
        }
    }

    /// Delimiters, environments, spacing and commands that only wrap their argument.
    private mutating func layout(_ name: String, previous: [MathNode]?) -> [MathNode]? {
        switch name {
        case "left":
            let open = delimiter()
            let inner = parseList(.right)
            var close = ""
            if hasCommand("right") {
                pos += "\\right".count
                close = delimiter()
            }
            return [.fenced(open, inner, close)]
        case "right": _ = delimiter(); return nil
        case "middle", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr", "bigm", "Bigm":
            let d = delimiter()
            return d.isEmpty ? nil : [.symbol(d, .upright)]
        case "begin": return environment(rawGroup())
        case "end", "label", "tag", "color", "hspace", "vspace", "hskip", "phantom", "vphantom", "hphantom", "ref", "eqref":
            _ = rawGroup()
            return name == "hspace" || name == "hskip" || name == "phantom" || name == "hphantom" ? [.space(0.5)] : nil
        case "limits", "nolimits":
            pendingLimits = name == "limits"
            return nil
        case "quad": return [.space(1)]
        case "qquad": return [.space(2)]
        case "enspace": return [.space(0.5)]
        case "thinspace": return [.space(0.17)]
        case "medspace": return [.space(0.22)]
        case "thickspace": return [.space(0.28)]
        case "textcolor":
            _ = rawGroup()
            return argument()
        case "boxed", "mathrel", "mathbin", "mathop", "mathord", "mathopen", "mathclose", "mathpunct", "ensuremath",
             "cancel", "bcancel", "xcancel", "smash", "overbrace", "underbrace", "displaylimits":
            return argument()
        case "stackrel", "overset":
            let top = argument()
            return [.scripts(base: argument(), superscript: top, subscript: nil)]
        case "underset":
            let bottom = argument()
            return [.scripts(base: argument(), superscript: nil, subscript: bottom)]
        case "xrightarrow", "xleftarrow":
            let below = optionalArgument()
            let above = argument()
            return [.scripts(base: [.operation(name == "xrightarrow" ? "⟶" : "⟵", .relation)], superscript: above, subscript: below)]
        case "not":
            skipSpaces()
            guard !isAtEnd, let next = nextAtom(previous: previous) else { return nil }
            if next.count == 1, case .operation(let s, let spacing) = next[0] { return [.operation(s + "\u{0338}", spacing)] }
            return next
        case "pmod": return [.space(0.5), .text("(mod")] + [.space(0.33)] + argument() + [.text(")")]
        case "bmod", "mod": return [.space(0.33), .text("mod"), .space(0.33)]
        case "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "nonumber", "notag", "allowbreak", "nobreak",
             "relax", "protect", "mathstrut", "strut", "centering", "hfill", "qedhere", "lefteqn":
            return nil
        default:
            return [.text(name)]
        }
    }

    // MARK: Environments

    private mutating func environment(_ name: String) -> [MathNode]? {
        let base = name.trimmingCharacters(in: ["*"])
        if base == "array" || base == "alignedat" || base == "alignat" { _ = rawGroup() }
        var rows: [[[MathNode]]] = []
        while !isAtEnd {
            var cells: [[MathNode]] = []
            while true {
                cells.append(parseList(.cell))
                if !isAtEnd, chars[pos] == "&" { pos += 1; continue }
                break
            }
            rows.append(cells)
            if hasPrefix("\\\\") {
                pos += 2
                _ = optionalRaw()
                continue
            }
            if hasCommand("cr") { pos += 3; continue }
            if hasCommand("end") {
                pos += 4
                _ = rawGroup()
                break
            }
            if !isAtEnd, chars[pos] == "}" { pos += 1; continue }
            break
        }
        while let last = rows.last, last.allSatisfy(\.isEmpty), rows.count > 1 { rows.removeLast() }
        return Self.wrap(rows, environment: base)
    }

    private static func wrap(_ rows: [[[MathNode]]], environment: String) -> [MathNode] {
        switch environment {
        case "pmatrix": [.fenced("(", [.table(rows, .matrix)], ")")]
        case "bmatrix": [.fenced("[", [.table(rows, .matrix)], "]")]
        case "Bmatrix": [.fenced("{", [.table(rows, .matrix)], "}")]
        case "vmatrix": [.fenced("|", [.table(rows, .matrix)], "|")]
        case "Vmatrix": [.fenced("‖", [.table(rows, .matrix)], "‖")]
        case "cases", "dcases": [.fenced("{", [.table(rows, .cases)], "")]
        case "rcases": [.fenced("", [.table(rows, .cases)], "}")]
        case "matrix", "smallmatrix", "array", "gathered", "gather", "multline": [.table(rows, .matrix)]
        default: [.table(rows, .aligned)]
        }
    }

    // MARK: Arguments

    /// A braced group or a single token, as math.
    private mutating func argument() -> [MathNode] {
        skipSpaces()
        guard !isAtEnd else { return [] }
        if chars[pos] == "{" {
            pos += 1
            let inner = parseList()
            if !isAtEnd, chars[pos] == "}" { pos += 1 }
            return inner
        }
        let saved = afterFunction
        defer { afterFunction = saved }
        return nextAtom(previous: nil) ?? []
    }

    /// `[…]` as math, or nil when there's none.
    private mutating func optionalArgument() -> [MathNode]? {
        skipSpaces()
        guard !isAtEnd, chars[pos] == "[" else { return nil }
        pos += 1
        let inner = parseList(.bracket)
        if !isAtEnd, chars[pos] == "]" { pos += 1 }
        return inner
    }

    private mutating func optionalRaw() -> String? {
        let saved = pos
        skipSpaces()
        guard !isAtEnd, chars[pos] == "[" else { pos = saved; return nil }
        var depth = 0
        var result = ""
        pos += 1
        while !isAtEnd {
            let c = chars[pos]
            pos += 1
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } else if c == "]", depth <= 0 { break }
            result.append(c)
        }
        return result
    }

    /// A braced group's characters as written (or one token without braces).
    private mutating func rawGroup() -> String {
        skipSpaces()
        guard !isAtEnd else { return "" }
        guard chars[pos] == "{" else {
            let c = chars[pos]
            pos += 1
            return String(c)
        }
        var depth = 0
        var result = ""
        while !isAtEnd {
            let c = chars[pos]
            pos += 1
            if c == "\\", !isAtEnd {
                result.append(c)
                result.append(chars[pos])
                pos += 1
                continue
            }
            if c == "{" { depth += 1; if depth == 1 { continue } }
            if c == "}" { depth -= 1; if depth == 0 { break } }
            result.append(c)
        }
        return result
    }

    /// The delimiter after `\left`, `\right` or `\big`: a character or a command; empty for `.`.
    private mutating func delimiter() -> String {
        skipSpaces()
        guard !isAtEnd else { return "" }
        let c = chars[pos]
        pos += 1
        if c == "." { return "" }
        guard c == "\\", !isAtEnd else { return String(c) }
        guard chars[pos].isLetter else {
            let escaped = chars[pos]
            pos += 1
            return escaped == "|" ? "‖" : String(escaped)
        }
        var name = ""
        while !isAtEnd, chars[pos].isLetter { name.append(chars[pos]); pos += 1 }
        return MathSymbols.delimiters[name] ?? ""
    }

    // MARK: Characters

    mutating func skipSpaces() {
        while !isAtEnd, chars[pos].isWhitespace { pos += 1 }
    }

    private func hasPrefix(_ prefix: String) -> Bool {
        var index = pos
        for c in prefix {
            guard index < chars.count, chars[index] == c else { return false }
            index += 1
        }
        return true
    }

    /// `\name` here, not followed by more letters.
    private func hasCommand(_ name: String) -> Bool {
        guard hasPrefix("\\" + name) else { return false }
        let end = pos + name.count + 1
        return end >= chars.count || !chars[end].isLetter
    }

    /// `\text{…}` contents as plain words.
    static func plainText(_ raw: String) -> String {
        let chars = Array(raw)
        var result = ""
        var index = 0
        while index < chars.count {
            let c = chars[index]
            index += 1
            switch c {
            case "{", "}", "$": continue
            case "~": result.append(" ")
            case "\\":
                guard index < chars.count else { break }
                let next = chars[index]
                index += 1
                if next.isLetter {
                    while index < chars.count, chars[index].isLetter { index += 1 }
                    continue
                }
                result.append(next == "," || next == ";" || next == " " ? " " : next)
            default: result.append(c)
            }
        }
        return result
    }
}
