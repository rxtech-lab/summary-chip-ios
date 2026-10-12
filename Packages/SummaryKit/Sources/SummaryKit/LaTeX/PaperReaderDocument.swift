import Foundation

/// A paper's LaTeX read as a document for the native reader: headings, paragraphs, formulas,
/// figures and tables in reading order, numbered the way LaTeX numbers them, with labels,
/// citations and footnotes resolved. Built from the source by `PaperReader`, not from the PDF.
public struct PaperReaderDocument: Sendable, Hashable {
    public var blocks: [PaperBlock] = []
    /// `\label` keys: what `\ref` prints, and the block to scroll to.
    public var labels: [String: PaperLabel] = [:]
    /// Bibliography numbers by citation key.
    public var citationNumbers: [String: Int] = [:]
    public var bibliography: [PaperBibEntry] = []
    /// Footnote texts; `PaperSpan.Kind.footnote(n)` is `footnotes[n - 1]`.
    public var footnotes: [[PaperSpan]] = []

    public init() {}

    public func bibEntry(_ key: String) -> PaperBibEntry? { bibliography.first { $0.key == key } }

    /// What a citation prints: `[1, 3]`, `Knuth [1]`, `Knuth`, `1984`.
    public func citationText(_ keys: [String], form: PaperCitationForm, note: String?) -> String {
        let numbers = keys.map { citationNumbers[$0].map(String.init) ?? $0 }
        let bracket = "[" + numbers.joined(separator: ", ") + (note.map { ", \($0)" } ?? "") + "]"
        switch form {
        case .numeric: return bracket
        case .textual: return keys.map { "\(bibEntry($0)?.shortAuthor ?? $0) [\(citationNumbers[$0].map(String.init) ?? $0)]" }.joined(separator: ", ")
        case .author: return keys.map { bibEntry($0)?.shortAuthor ?? $0 }.joined(separator: ", ")
        case .year: return keys.map { bibEntry($0)?.year ?? "?" }.joined(separator: ", ")
        }
    }

    /// What a reference prints: `3`, `(3)`, `Figure 3`; `??` for a label the paper doesn't have.
    public func referenceText(_ key: String, form: PaperReferenceForm) -> String {
        guard let label = labels[key] else { return "??" }
        switch form {
        case .number: return label.number
        case .equation: return "(\(label.number))"
        case .named: return label.kind == .equation ? "\(label.name) (\(label.number))" : "\(label.name) \(label.number)"
        case .page: return label.number
        }
    }
}

public struct PaperLabel: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case section, figure, table, equation, theorem, item, other }
    public var kind: Kind
    public var number: String
    /// What `\autoref` calls it: `Section`, `Figure`, `Theorem`.
    public var name: String
    /// The block to scroll to.
    public var block: Int
}

public struct PaperBlock: Sendable, Hashable, Identifiable {
    public var id: Int
    public var kind: Kind

    public indirect enum Kind: Sendable, Hashable {
        case title(PaperTitle)
        case heading(PaperHeading)
        case paragraph([PaperSpan], PaperAlignment)
        case equation(PaperEquation)
        case figure(PaperFigure)
        case table(PaperTable)
        case list(PaperList)
        case quote([PaperBlock])
        case abstract([PaperBlock])
        case theorem(PaperTheorem)
        case code(String, language: String?)
        /// `\tableofcontents`: the numbered headings.
        case contents([PaperHeading])
        /// Where `\bibliography` prints `PaperReaderDocument.bibliography`.
        case bibliography
    }

    public init(id: Int, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public enum PaperAlignment: Sendable, Hashable { case leading, center, trailing }

public struct PaperTitle: Sendable, Hashable {
    public var title: [PaperSpan]
    public var authors: [[PaperSpan]]
    public var date: [PaperSpan]?
}

public struct PaperHeading: Sendable, Hashable {
    /// 1 for the paper's top sectioning level (chapters in a report, sections in an article).
    public var level: Int
    public var number: String?
    public var title: [PaperSpan]
    public var block: Int
}

public struct PaperEquation: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        /// Cells split at `&`; one cell unless the environment aligns.
        public var cells: [[MathNode]]
        public var number: String?
    }

    public var rows: [Row]
    /// `align`-style: cells alternate right and left aligned.
    public var isAligned: Bool
    /// The LaTeX, for copying and VoiceOver.
    public var source: String
}

public struct PaperFigure: Sendable, Hashable {
    public struct Image: Sendable, Hashable {
        /// The paper file shown, or nil when `\includegraphics` names a file the paper doesn't have.
        public var path: String?
        public var requested: String
        /// `width=0.5\linewidth`: the share of the text width.
        public var width: Double?
        /// A subfigure's own caption.
        public var caption: [PaperSpan]?
    }

    public var images: [Image]
    /// TikZ pictures and pgfplots charts, which LaTeX draws (`drawingSources`, one each).
    public var drawings: Int
    public var caption: [PaperSpan]?
    /// `Figure 3`, `Table 2`; nil without a caption.
    public var number: String?
    public var name: String
    /// Each drawing's environment as written (`\begin{tikzpicture}…\end{tikzpicture}`), for
    /// the server to draw on its own.
    public var drawingSources: [String] = []
}

public struct PaperTable: Sendable, Hashable {
    public struct Cell: Sendable, Hashable {
        public var content: [PaperSpan]
        /// `\multicolumn`: how many columns it spans.
        public var columns: Int
    }

    public var rows: [[Cell]]
    /// Rows above the first rule after the top one: the header.
    public var headerRows: Int
    public var alignments: [PaperAlignment]
    public var caption: [PaperSpan]?
    public var number: String?
    public var name: String
    /// Images or drawings in the same float, shown above the table.
    public var figure: PaperFigure?
}

public struct PaperList: Sendable, Hashable {
    public enum Style: Sendable, Hashable { case bullet, numbered, description }

    public struct Item: Sendable, Hashable {
        /// `\item[…]`, or nil for the list's own marker.
        public var label: [PaperSpan]?
        public var blocks: [PaperBlock]
    }

    public var style: Style
    /// 0 for a top-level list: numbered lists count 1., a., i., A. by depth.
    public var depth: Int
    public var items: [Item]

    /// The marker before item `index`.
    public func marker(_ index: Int) -> String {
        switch style {
        case .bullet: return ["•", "–", "∗", "·"][depth % 4]
        case .description: return ""
        case .numbered:
            let n = index + 1
            switch depth % 4 {
            case 0: return "\(n)."
            case 1: return "(\(Self.letter(n)))"
            case 2: return "\(Self.roman(n))."
            default: return "\(Self.letter(n).uppercased())."
            }
        }
    }

    static func letter(_ n: Int) -> String {
        guard n > 0, n <= 26, let scalar = UnicodeScalar(96 + n) else { return String(n) }
        return String(Character(scalar))
    }

    static func roman(_ n: Int) -> String {
        let numerals: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var rest = n
        var result = ""
        for (value, numeral) in numerals {
            while rest >= value { result += numeral; rest -= value }
        }
        return result
    }
}

public struct PaperTheorem: Sendable, Hashable {
    /// `Theorem`, `Definition`, `Proof`.
    public var name: String
    public var number: String?
    /// `\begin{theorem}[Fermat]`.
    public var note: [PaperSpan]?
    public var blocks: [PaperBlock]
    /// Proofs are set upright with a closing square.
    public var isProof: Bool
}

public struct PaperBibEntry: Sendable, Hashable, Identifiable {
    public var key: String
    public var number: Int
    /// The formatted reference.
    public var text: [PaperSpan]
    /// The first author's last name, for `\citet`.
    public var shortAuthor: String?
    public var year: String?
    public var url: String?

    public var id: String { key }
}

public enum PaperCitationForm: Sendable, Hashable {
    /// `\cite`: `[1]`.
    case numeric
    /// `\citet`: `Knuth [1]`.
    case textual
    case author
    case year
}

public enum PaperReferenceForm: Sendable, Hashable {
    /// `\ref`: `3`.
    case number
    /// `\eqref`: `(3)`.
    case equation
    /// `\autoref`, `\cref`: `Figure 3`.
    case named
    case page
}

public struct PaperTextStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = PaperTextStyle(rawValue: 1)
    public static let italic = PaperTextStyle(rawValue: 2)
    public static let monospace = PaperTextStyle(rawValue: 4)
    public static let smallCaps = PaperTextStyle(rawValue: 8)
    public static let underline = PaperTextStyle(rawValue: 16)
    public static let strikethrough = PaperTextStyle(rawValue: 32)
    public static let sansSerif = PaperTextStyle(rawValue: 64)
}

/// A run of paragraph content in one style.
public struct PaperSpan: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case text(String)
        case math([MathNode], source: String)
        /// `\href`, `\url`.
        case link(String, url: String)
        case citation([String], form: PaperCitationForm, note: String?)
        case reference(String, form: PaperReferenceForm)
        /// The footnote's number.
        case footnote(Int)
        /// `\\`, `\newline`.
        case lineBreak
    }

    public var kind: Kind
    public var style: PaperTextStyle

    public init(_ kind: Kind, style: PaperTextStyle = []) {
        self.kind = kind
        self.style = style
    }

    public static func text(_ text: String, style: PaperTextStyle = []) -> PaperSpan { PaperSpan(.text(text), style: style) }
}

public extension Array where Element == PaperSpan {
    /// The spans as plain text, with formulas as their LaTeX.
    var plainText: String {
        map { span in
            switch span.kind {
            case .text(let text): text
            case .math(_, let source): source
            case .link(let text, _): text
            case .citation(let keys, _, _): "[\(keys.joined(separator: ", "))]"
            case .reference(let key, _): key
            case .footnote(let n): "[\(n)]"
            case .lineBreak: "\n"
            }
        }.joined()
    }
}
