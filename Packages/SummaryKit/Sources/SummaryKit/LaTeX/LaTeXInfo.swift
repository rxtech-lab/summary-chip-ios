import Foundation

/// What a hover card says about the word under the pointer.
public struct LaTeXHoverInfo: Sendable, Equatable {
    /// The word described, to anchor the card.
    public let range: NSRange
    /// `\frac{…}{…}`, `figure`, `knuth84`.
    public let title: String
    public let detail: String
    /// A line of source shown in monospace: where a command or label is defined.
    public let source: String?
    /// The word is a reference to something the paper doesn't have.
    public let isProblem: Bool

    public init(range: NSRange, title: String, detail: String, source: String? = nil, isProblem: Bool = false) {
        self.range = range
        self.title = title
        self.detail = detail
        self.source = source
        self.isProblem = isProblem
    }
}

/// Descriptions for hover cards: built-in commands, environments and packages, the paper's own
/// commands and environments (where they're defined), citation keys (the entry) and labels.
public enum LaTeXInfo {
    public static func info(in text: String, at index: Int, symbols: LaTeXSymbols) -> LaTeXHoverInfo? {
        let string = text as NSString
        guard index >= 0, index < string.length else { return nil }
        return commandInfo(string, index, symbols) ?? argumentInfo(string, index, symbols)
    }

    private static func commandInfo(_ string: NSString, _ index: Int, _ symbols: LaTeXSymbols) -> LaTeXHoverInfo? {
        var start = string.character(at: index) == LaTeXCompletion.backslash ? index + 1 : index
        while start > 0, LaTeXCompletion.isCommandLetter(string.character(at: start - 1)) { start -= 1 }
        var end = start
        while end < string.length, LaTeXCompletion.isCommandLetter(string.character(at: end)) { end += 1 }
        guard end > start, start > 0, string.character(at: start - 1) == LaTeXCompletion.backslash,
              !LaTeXCompletion.isEscaped(string, start - 1) else { return nil }
        if end < string.length, string.character(at: end) == UInt16(UnicodeScalar("*").value) { end += 1 }
        let name = string.substring(with: NSRange(location: start, length: end - start))
        let range = NSRange(location: start - 1, length: end - start + 1)
        if let definition = symbols.commandDefinitions[name] {
            return LaTeXHoverInfo(range: range, title: "\\" + name, detail: "Defined in \(definition.file):\(definition.line)", source: definition.text)
        }
        guard let command = LaTeXCatalog.command(name) ?? LaTeXCatalog.command(name.trimmingCharacters(in: ["*"])) else { return nil }
        return LaTeXHoverInfo(range: range, title: command.signature, detail: command.description)
    }

    private static func argumentInfo(_ string: NSString, _ index: Int, _ symbols: LaTeXSymbols) -> LaTeXHoverInfo? {
        guard let word = argumentWord(string, index) else { return nil }
        let key = string.substring(with: word.range)
        switch word.kind {
        case .beginEnvironment, .endEnvironment:
            if let definition = symbols.environmentDefinitions[key] {
                return LaTeXHoverInfo(range: word.range, title: key, detail: "Defined in \(definition.file):\(definition.line)", source: definition.text)
            }
            return LaTeXCatalog.environment(key).map { LaTeXHoverInfo(range: word.range, title: key, detail: $0.description) }
        case .citation:
            guard let citation = symbols.citation(key) else {
                return LaTeXHoverInfo(range: word.range, title: key, detail: "Not in the paper's .bib files.", isProblem: true)
            }
            return LaTeXHoverInfo(range: word.range, title: key, detail: LaTeXCompletion.citationDetail(citation) ?? "A bibliography entry.")
        case .reference:
            guard let label = symbols.labelDefinitions[key] else {
                return LaTeXHoverInfo(range: word.range, title: key, detail: "No \\label{\(key)} in the paper.", isProblem: true)
            }
            return LaTeXHoverInfo(range: word.range, title: key, detail: "Labelled in \(label.file):\(label.line)", source: label.text)
        case .package:
            return LaTeXCatalog.package(key).map { LaTeXHoverInfo(range: word.range, title: key, detail: $0.description) }
        default:
            return nil
        }
    }

    /// The comma-separated key under `index` inside a command's `{…}` argument, on one line.
    private static func argumentWord(_ string: NSString, _ index: Int) -> (kind: LaTeXCompletionContext.Kind, range: NSRange)? {
        let stops: Set<UInt16> = [unit("{"), unit("}"), unit(","), unit("\n")]
        var start = index
        while start > 0, !stops.contains(string.character(at: start - 1)) { start -= 1 }
        var end = index
        while end < string.length, !stops.contains(string.character(at: end)) { end += 1 }
        guard !stops.contains(string.character(at: index)) else { return nil }
        // Back to the opening brace, past earlier keys of a list.
        var brace = start
        while brace > 0, string.character(at: brace - 1) == unit(",") || !stops.contains(string.character(at: brace - 1)) { brace -= 1 }
        guard brace > 0, string.character(at: brace - 1) == unit("{"),
              let command = LaTeXCompletion.commandName(before: brace - 1, in: string),
              let kind = LaTeXCompletion.argumentKind(command) else { return nil }
        var range = NSRange(location: start, length: end - start)
        let key = string.substring(with: range)
        let leading = key.prefix { $0 == " " }.utf16.count
        let trailing = key.reversed().prefix { $0 == " " }.count
        range = NSRange(location: range.location + leading, length: max(0, range.length - leading - trailing))
        return range.length > 0 ? (kind, range) : nil
    }

    private static func unit(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }
}
