import Foundation

/// What a paper defines across all its files, for completing references, citations, file paths
/// and the commands and environments it declares itself, and for saying where in hover cards.
public struct LaTeXSymbols: Sendable, Equatable {
    public struct Citation: Sendable, Equatable {
        public let key: String
        public let title: String?
        /// `Knuth, Donald E.`, as written in the entry.
        public let author: String?
        public let year: String?
    }

    /// Where something is defined: the file, its 1-based line, and that line's text.
    public struct Location: Sendable, Equatable {
        public let file: String
        public let line: Int
        public let text: String
    }

    /// `\newcommand{\R}`, `\def\R`, `\DeclareMathOperator{\argmax}`: names without the backslash.
    public var commands: [String] = []
    /// `\newenvironment{note}`, `\newtheorem{claim}`.
    public var environments: [String] = []
    /// `\label{…}` keys.
    public var labels: [String] = []
    /// BibTeX entry keys from the `.bib` files.
    public var citations: [Citation] = []
    /// `.tex` files as `\input` takes them: `sections/intro`.
    public var texFiles: [String] = []
    /// Images as `\includegraphics` takes them.
    public var graphics: [String] = []
    /// `.bib` files: `references.bib`.
    public var bibFiles: [String] = []

    /// The first definition of each of `commands`, `environments` and `labels`.
    public var commandDefinitions: [String: Location] = [:]
    public var environmentDefinitions: [String: Location] = [:]
    public var labelDefinitions: [String: Location] = [:]

    public init() {}

    public init(source: PaperSource) {
        for file in source.files where !file.isImage {
            switch LaTeXLanguage(fileExtension: file.fileExtension) {
            case .tex: scanTeX(file)
            case .bibtex: scanBib(file.content)
            case .plain: break
            }
        }
        commands = Self.unique(commands)
        environments = Self.unique(environments)
        labels = Self.unique(labels)
        texFiles = source.files.filter { $0.isTeX && $0.path != source.mainFile }.map { ($0.path as NSString).deletingPathExtension }
        graphics = source.files.filter { ["png", "jpg", "jpeg", "pdf", "eps"].contains($0.fileExtension) }.map(\.path)
        bibFiles = source.files.filter { $0.fileExtension == "bib" }.map(\.path)
    }

    public func citation(_ key: String) -> Citation? { citations.first { $0.key == key } }

    private mutating func scanTeX(_ file: PaperFile) {
        let text = file.content
        let string = text as NSString
        let lines = LaTeXLineIndex(text)
        func location(_ range: NSRange) -> Location {
            let line = lines.line(at: range.location)
            let lineRange = lines.range(ofLine: line) ?? range
            return Location(file: file.path, line: line, text: string.substring(with: lineRange).trimmingCharacters(in: .whitespaces))
        }
        for (name, range) in Self.matches(Self.commandDefinition, in: string) {
            commands.append(name)
            if commandDefinitions[name] == nil { commandDefinitions[name] = location(range) }
        }
        for (name, range) in Self.matches(Self.environmentDefinition, in: string) {
            environments.append(name)
            if environmentDefinitions[name] == nil { environmentDefinitions[name] = location(range) }
        }
        for (name, range) in Self.matches(Self.label, in: string) {
            labels.append(name)
            if labelDefinitions[name] == nil { labelDefinitions[name] = location(range) }
        }
    }

    private mutating func scanBib(_ text: String) {
        let string = text as NSString
        let entries = Self.bibEntry.matches(in: text, range: NSRange(location: 0, length: string.length))
        for (index, entry) in entries.enumerated() {
            let type = string.substring(with: entry.range(at: 1)).lowercased()
            guard !["string", "comment", "preamble"].contains(type) else { continue }
            let end = index + 1 < entries.count ? entries[index + 1].range.location : string.length
            let body = NSRange(location: entry.range.location, length: end - entry.range.location)
            func field(_ name: String) -> String? {
                Self.field(name).firstMatch(in: text, range: body).map {
                    string.substring(with: $0.range(at: 1)).replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                }
            }
            citations.append(Citation(
                key: string.substring(with: entry.range(at: 2)),
                title: field("title"),
                author: field("author"),
                year: field("year")
            ))
        }
    }

    /// The first capture group that matched, and where the whole match is.
    private static func matches(_ regex: NSRegularExpression, in string: NSString) -> [(String, NSRange)] {
        regex.matches(in: string as String, range: NSRange(location: 0, length: string.length)).compactMap { match in
            (1..<match.numberOfRanges).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
                .map { (string.substring(with: $0), match.range) }
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Literal patterns: a typo is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static func field(_ name: String) -> NSRegularExpression {
        switch name {
        case "title": bibTitle
        case "author": bibAuthor
        default: bibYear
        }
    }

    private static let commandDefinition = regex(
        #"\\(?:(?:re|provide)?newcommand|DeclareMathOperator|DeclareRobustCommand)\*?\s*\{?\s*\\([A-Za-z@]+)|\\[egx]?def\s*\\([A-Za-z@]+)"#
    )
    private static let environmentDefinition = regex(#"\\(?:newenvironment|newtheorem)\*?\s*\{([^}\s]+)\}"#)
    private static let label = regex(#"\\label\s*\{([^}\s]+)\}"#)
    private static let bibEntry = regex(#"@([A-Za-z]+)\s*[{(]\s*([^,\s]+)\s*,"#)
    private static let bibTitle = regex(#"^\s*title\s*=\s*[{"](.+?)[}"]?\s*,?\s*$"#)
    private static let bibAuthor = regex(#"^\s*author\s*=\s*[{"](.+?)[}"]?\s*,?\s*$"#)
    private static let bibYear = regex(#"\byear\s*=\s*[{"]?(\d{4})"#)
}
