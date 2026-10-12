import Foundation

/// What math commands draw: Unicode for symbols, operators and letter styles.
enum MathSymbols {
    static func node(for name: String) -> MathNode? {
        if let letter = greek[name] { return .symbol(letter, name.first?.isLowercase == true ? .italic : .upright) }
        if let symbol = ordinary[name] { return .symbol(symbol, .upright) }
        if let symbol = binary[name] { return .operation(symbol, .binary) }
        if let symbol = relations[name] { return .operation(symbol, .relation) }
        if let symbol = largeOperators[name] { return .largeOperator(symbol.0, limits: symbol.1) }
        if let symbol = delimiters[name] { return .symbol(symbol, .upright) }
        return nil
    }

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    static let ordinary: [String: String] = [
        "infty": "∞", "partial": "∂", "nabla": "∇", "ell": "ℓ", "hbar": "ℏ", "hslash": "ℏ", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬", "prime": "′", "angle": "∠", "triangle": "△",
        "aleph": "ℵ", "Re": "ℜ", "Im": "ℑ", "wp": "℘", "top": "⊤", "bot": "⊥", "degree": "°", "circ": "∘", "bullet": "•",
        "ldots": "…", "dots": "…", "dotsc": "…", "dotsb": "⋯", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "imath": "ı",
        "jmath": "ȷ", "Box": "□", "square": "□", "checkmark": "✓", "dagger": "†", "ddagger": "‡", "S": "§", "P": "¶",
        "sharp": "♯", "flat": "♭", "natural": "♮", "clubsuit": "♣", "diamondsuit": "♢", "heartsuit": "♡", "spadesuit": "♠",
        "colon": ":", "backslash": "\\", "lbrace": "{", "rbrace": "}", "vert": "|", "Vert": "‖", "mid": "∣",
    ]

    static let binary: [String: String] = [
        "pm": "±", "mp": "∓", "times": "×", "cdot": "⋅", "div": "÷", "ast": "∗", "star": "⋆", "cup": "∪", "cap": "∩",
        "sqcup": "⊔", "sqcap": "⊓", "vee": "∨", "lor": "∨", "wedge": "∧", "land": "∧", "oplus": "⊕", "ominus": "⊖",
        "otimes": "⊗", "oslash": "⊘", "odot": "⊙", "setminus": "∖", "smallsetminus": "∖", "uplus": "⊎", "amalg": "⨿",
        "diamond": "⋄", "bigcirc": "◯", "wr": "≀", "cdotp": "⋅", "dotplus": "∔", "ltimes": "⋉", "rtimes": "⋊",
    ]

    static let relations: [String: String] = [
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆",
        "supset": "⊃", "supseteq": "⊇", "subsetneq": "⊊", "supsetneq": "⊋", "to": "→", "rightarrow": "→", "leftarrow": "←",
        "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "leftrightarrow": "↔", "iff": "⟺",
        "implies": "⟹", "impliedby": "⟸", "mapsto": "↦", "longmapsto": "⟼", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "Longrightarrow": "⟹", "Longleftarrow": "⟸", "Longleftrightarrow": "⟺", "uparrow": "↑", "downarrow": "↓",
        "Uparrow": "⇑", "Downarrow": "⇓", "updownarrow": "↕", "nearrow": "↗", "searrow": "↘", "hookrightarrow": "↪",
        "ll": "≪", "gg": "≫", "perp": "⊥", "parallel": "∥", "models": "⊨", "vdash": "⊢", "dashv": "⊣", "asymp": "≍",
        "doteq": "≐", "coloneqq": "≔", "eqqcolon": "≕", "triangleq": "≜", "leqslant": "⩽", "geqslant": "⩾", "lesssim": "≲",
        "gtrsim": "≳", "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰", "sqsubseteq": "⊑", "sqsupseteq": "⊒",
        "nleq": "≰", "ngeq": "≱", "nsim": "≁", "ncong": "≇", "nmid": "∤", "nparallel": "∦", "rightleftharpoons": "⇌",
        "leadsto": "⇝", "approxeq": "≊", "bowtie": "⋈", "smile": "⌣", "frown": "⌢", "therefore": "∴", "because": "∵",
    ]

    /// Symbol, and whether display formulas put its scripts above and below.
    static let largeOperators: [String: (String, Bool)] = [
        "sum": ("∑", true), "prod": ("∏", true), "coprod": ("∐", true), "bigcup": ("⋃", true), "bigcap": ("⋂", true),
        "bigoplus": ("⨁", true), "bigotimes": ("⨂", true), "bigodot": ("⨀", true), "bigvee": ("⋁", true),
        "bigwedge": ("⋀", true), "biguplus": ("⨄", true), "bigsqcup": ("⨆", true),
        "int": ("∫", false), "iint": ("∬", false), "iiint": ("∭", false), "oint": ("∮", false), "oiint": ("∯", false),
    ]

    /// Upright function names: `\sin x`.
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth", "log", "ln",
        "lg", "exp", "arg", "deg", "dim", "ker", "hom", "sgn", "Tr", "tr", "rank", "diag", "span", "erf",
    ]

    /// Function names whose scripts go underneath in display formulas: `\lim_{x \to 0}`.
    static let limitFunctions: [String: String] = [
        "lim": "lim", "max": "max", "min": "min", "sup": "sup", "inf": "inf", "det": "det", "Pr": "Pr", "gcd": "gcd",
        "liminf": "lim inf", "limsup": "lim sup", "argmax": "arg max", "argmin": "arg min", "esssup": "ess sup",
    ]

    static let delimiters: [String: String] = [
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "lvert": "|", "rvert": "|",
        "lVert": "‖", "rVert": "‖", "vert": "|", "Vert": "‖", "lbrace": "{", "rbrace": "}", "lbrack": "[", "rbrack": "]",
        "{": "{", "}": "}", "backslash": "\\", "uparrow": "↑", "downarrow": "↓", "llbracket": "⟦", "rrbracket": "⟧",
    ]

    // MARK: Letter styles

    enum Alphabet { case doubleStruck, script, fraktur }

    /// The letters (and digits) of `nodes` in a Unicode math alphabet.
    static func restyle(_ nodes: [MathNode], alphabet: Alphabet) -> [MathNode] {
        map(nodes) { text, font in
            let styled = String(text.map { letter($0, in: alphabet) })
            return styled == text ? (text, font) : (styled, .upright)
        }
    }

    /// The letters and numbers of `nodes` in another font.
    static func restyle(_ nodes: [MathNode], font: MathFont) -> [MathNode] {
        map(nodes) { text, _ in (text, font) }
    }

    private static func map(_ nodes: [MathNode], _ transform: (String, MathFont) -> (String, MathFont)) -> [MathNode] {
        nodes.map { node in
            switch node {
            case .symbol(let text, let font):
                let (text, font) = transform(text, font)
                return .symbol(text, font)
            case .scripts(let base, let sup, let sub):
                return .scripts(base: map(base, transform), superscript: sup, subscript: sub)
            case .accent(let inner, let accent):
                return .accent(map(inner, transform), accent)
            default:
                return node
            }
        }
    }

    private static func letter(_ c: Character, in alphabet: Alphabet) -> Character {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1, scalar.isASCII else { return c }
        let exceptions: [Character: Character]
        let upper: UInt32, lower: UInt32?
        switch alphabet {
        case .doubleStruck:
            exceptions = ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"]
            upper = 0x1D538; lower = 0x1D552
            if c.isNumber, let digit = c.wholeNumberValue { return Character(UnicodeScalar(0x1D7D8 + UInt32(digit))!) }
        case .script:
            exceptions = ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ", "e": "ℯ", "g": "ℊ", "o": "ℴ"]
            upper = 0x1D49C; lower = 0x1D4B6
        case .fraktur:
            exceptions = ["C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ"]
            upper = 0x1D504; lower = 0x1D51E
        }
        if let exception = exceptions[c] { return exception }
        let value = scalar.value
        if (65...90).contains(value), let styled = UnicodeScalar(upper + value - 65) { return Character(styled) }
        if (97...122).contains(value), let lower, let styled = UnicodeScalar(lower + value - 97) { return Character(styled) }
        return c
    }
}

// MARK: - Inline formulas

/// A piece of an inline formula as styled text.
public struct MathRun: Sendable, Hashable {
    public var text: String
    public var font: MathFont
    /// Size relative to the surrounding text.
    public var scale: Double
    /// Baseline shift, in em of the surrounding text.
    public var baseline: Double
}

extension PaperMath {
    /// An inline formula as text runs: scripts become smaller raised or lowered runs, fractions
    /// `a/b`, roots `√x` and accents combining marks.
    public static func runs(_ nodes: [MathNode]) -> [MathRun] {
        var builder = MathRunBuilder()
        builder.add(nodes, scale: 1, baseline: 0)
        return builder.runs
    }
}

private struct MathRunBuilder {
    var runs: [MathRun] = []

    mutating func append(_ text: String, _ font: MathFont, scale: Double, baseline: Double) {
        guard !text.isEmpty else { return }
        if let last = runs.last, last.font == font, last.scale == scale, last.baseline == baseline {
            runs[runs.count - 1].text += text
        } else {
            runs.append(MathRun(text: text, font: font, scale: scale, baseline: baseline))
        }
    }

    mutating func add(_ nodes: [MathNode], scale: Double, baseline: Double) {
        for node in nodes { add(node, scale: scale, baseline: baseline) }
    }

    // swiftlint:disable:next cyclomatic_complexity
    mutating func add(_ node: MathNode, scale: Double, baseline: Double) {
        let spaced = scale >= 1
        switch node {
        case .symbol(let text, let font):
            append(text, font, scale: scale, baseline: baseline)
        case .operation(let text, let spacing):
            let padded = switch spacing {
            case .binary: spaced ? "\u{2005}\(text)\u{2005}" : text
            case .relation: spaced ? "\u{2004}\(text)\u{2004}" : text
            case .punctuation: "\(text)\u{2009}"
            }
            append(padded, .upright, scale: scale, baseline: baseline)
        case .largeOperator(let text, _), .text(let text):
            append(text, .upright, scale: scale, baseline: baseline)
        case .space(let em):
            append(em >= 1 ? String(repeating: "\u{2003}", count: Int(em)) : em >= 0.25 ? "\u{2005}" : em > 0 ? "\u{2009}" : "", .upright, scale: scale, baseline: baseline)
        case .fraction(let numerator, let denominator, let line):
            addGrouped(numerator, scale: scale, baseline: baseline)
            append(line ? "/" : ",", .upright, scale: scale, baseline: baseline)
            addGrouped(denominator, scale: scale, baseline: baseline)
        case .scripts(let base, let sup, let sub):
            add(base, scale: scale, baseline: baseline)
            let small = max(scale * 0.7, 0.5)
            if let sup { add(sup, scale: small, baseline: baseline + 0.4 * scale) }
            if let sub { add(sub, scale: small, baseline: baseline - 0.2 * scale) }
        case .radical(let inner, let index):
            if let index { add(index, scale: max(scale * 0.6, 0.5), baseline: baseline + 0.45 * scale) }
            append("√", .upright, scale: scale, baseline: baseline)
            addGrouped(inner, scale: scale, baseline: baseline)
        case .accent(let inner, let accent):
            addAccented(inner, accent, scale: scale, baseline: baseline)
        case .fenced(let open, let inner, let close):
            append(open, .upright, scale: scale, baseline: baseline)
            add(inner, scale: scale, baseline: baseline)
            append(close, .upright, scale: scale, baseline: baseline)
        case .table(let rows, _):
            for (index, row) in rows.enumerated() {
                if index > 0 { append(";\u{2004}", .upright, scale: scale, baseline: baseline) }
                for (column, cell) in row.enumerated() {
                    if column > 0 { append("\u{2004}", .upright, scale: scale, baseline: baseline) }
                    add(cell, scale: scale, baseline: baseline)
                }
            }
        }
    }

    /// Parentheses around anything longer than one symbol, so `a+b/c` reads `(a+b)/c`.
    private mutating func addGrouped(_ nodes: [MathNode], scale: Double, baseline: Double) {
        let simple: Bool = switch nodes.first {
        case .symbol?, .text?, .fenced?: nodes.count == 1
        case .scripts(let base, _, _)?: nodes.count == 1 && base.count == 1
        default: false
        }
        if !simple { append("(", .upright, scale: scale, baseline: baseline) }
        add(nodes, scale: scale, baseline: baseline)
        if !simple { append(")", .upright, scale: scale, baseline: baseline) }
    }

    private mutating func addAccented(_ inner: [MathNode], _ accent: MathAccent, scale: Double, baseline: Double) {
        var nested = MathRunBuilder()
        nested.add(inner, scale: scale, baseline: baseline)
        let marksEveryLetter = accent == .bar || accent == .underline
        for run in nested.runs {
            var text = ""
            let letters = Array(run.text)
            for (index, letter) in letters.enumerated() {
                text.append(letter)
                if letter.isLetter || letter.isNumber, marksEveryLetter || index == letters.count - 1 {
                    text += accent.combining
                }
            }
            append(text, run.font, scale: run.scale, baseline: run.baseline)
        }
    }
}
