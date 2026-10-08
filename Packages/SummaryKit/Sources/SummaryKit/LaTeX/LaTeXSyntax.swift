import Foundation

/// The grammar a paper file is highlighted with, from its extension.
public enum LaTeXLanguage: Sendable, Equatable {
    case tex
    case bibtex
    /// Data and anything else: shown as typed.
    case plain

    public init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "tex", "sty", "cls", "def", "cfg", "clo", "bbx", "cbx", "lbx", "tikz", "ltx", "dtx": self = .tex
        case "bib": self = .bibtex
        default: self = .plain
        }
    }
}

/// One highlighted stretch of a file. Ranges are UTF-16 (`NSString`) ranges.
public struct LaTeXToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable, CaseIterable {
        /// `\section`, `\alpha`, `\\`.
        case command
        /// The name in `\begin{figure}` / `\end{figure}`.
        case environment
        /// A key or path argument: `\label{eq:1}`, `\cite{knuth84}`, `\usepackage{amsmath}`.
        case argument
        /// A sectioning title: `\section{Introduction}`.
        case heading
        /// `$x^2$`, `\[ … \]`, `\( … \)`, `$$ … $$`.
        case math
        /// `{ } [ ]`.
        case delimiter
        /// `% …` to the end of the line.
        case comment
        /// BibTeX `@article`.
        case entryType
        /// BibTeX `title =`.
        case field
    }

    public let kind: Kind
    public let range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

/// A small regex highlighter for LaTeX and BibTeX. It doesn't parse TeX (nothing short of running
/// TeX can); it colours what a reader scans for. Tokens come out in paint order: later ones sit on
/// top, so a comment wins over a command inside it.
public enum LaTeXSyntax {
    /// The tokens in `range` of `text` (all of it when nil). Patterns that span lines (display math)
    /// only match when they lie wholly inside `range`.
    public static func tokens(in text: String, language: LaTeXLanguage, range: NSRange? = nil) -> [LaTeXToken] {
        let string = text as NSString
        let scope = range ?? NSRange(location: 0, length: string.length)
        let rules: [Rule] = switch language {
        case .tex: texRules
        case .bibtex: bibRules
        case .plain: []
        }
        var tokens: [LaTeXToken] = []
        for rule in rules {
            rule.regex.enumerateMatches(in: text, range: scope) { match, _, _ in
                guard let match else { return }
                let found = match.range(at: rule.group)
                if found.location != NSNotFound, found.length > 0 {
                    tokens.append(LaTeXToken(kind: rule.kind, range: found))
                }
            }
        }
        return tokens
    }

    private struct Rule: Sendable {
        let kind: LaTeXToken.Kind
        let regex: NSRegularExpression
        let group: Int

        init(_ kind: LaTeXToken.Kind, _ pattern: String, group: Int = 0) {
            self.kind = kind
            // The patterns are literals below; a typo is a programming error caught by the tests.
            self.regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            self.group = group
        }
    }

    private static let texRules: [Rule] = [
        Rule(.math, #"\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|(?<![\\$])\$(?:\\.|[^$\\\n])+\$"#),
        Rule(.delimiter, #"(?<!\\)[{}\[\]]"#),
        Rule(.command, #"\\(?:[A-Za-z@]+\*?|.)"#),
        Rule(.environment, #"\\(?:begin|end)\{([^}\n]*)\}"#, group: 1),
        Rule(.argument, argumentPattern, group: 1),
        Rule(.heading, #"\\(?:part|chapter|section|subsection|subsubsection|paragraph|subparagraph|title|caption)\*?(?:\[[^\]\n]*\])?\{([^}\n]*)\}"#, group: 1),
        Rule(.comment, #"(?<!\\)%.*$"#),
    ]

    private static let argumentPattern =
        #"\\(?:label|[a-zA-Z]*ref|[a-zA-Z]*cite[a-zA-Z]*|input|include|subfile|includegraphics|bibliography|addbibresource|"#
        + #"bibliographystyle|usepackage|RequirePackage|documentclass)\*?(?:\[[^\]\n]*\])*\{([^}\n]*)\}"#

    private static let bibRules: [Rule] = [
        Rule(.delimiter, #"[{}]"#),
        Rule(.field, #"^\s*([A-Za-z][\w-]*)\s*="#, group: 1),
        Rule(.entryType, #"@[A-Za-z]+"#),
        Rule(.argument, #"@[A-Za-z]+\s*\{\s*([^,\s}]+)"#, group: 1),
        Rule(.comment, #"^\s*%.*$"#),
    ]
}
