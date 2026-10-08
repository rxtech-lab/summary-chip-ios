import Foundation

/// What the word at the caret is completing. Ranges are UTF-16 (`NSString`) ranges.
public struct LaTeXCompletionContext: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `\sec|`: the range includes the backslash.
        case command
        case beginEnvironment
        case endEnvironment
        /// `\cite{knu|`, also after a comma.
        case citation
        /// `\ref{fig:|`.
        case reference
        /// `\input{sec|`.
        case texFile
        /// `\includegraphics{fig|`.
        case graphic
        /// `\bibliography{ref|` (no extension) or `\addbibresource{ref|` (with it).
        case bibliography(withExtension: Bool)
        /// `\usepackage{ams|`.
        case package
    }

    public let kind: Kind
    /// The typed part, from the word's start to the caret.
    public let range: NSRange
    /// The typed text without a command's backslash.
    public let prefix: String
}

/// One completion: `label` is what the list shows and what replaces the typed word.
public struct LaTeXSuggestion: Sendable, Hashable, Identifiable {
    public let label: String
    public let detail: String?
    /// Typed after the label for a command: `{}` puts the caret between the braces.
    let arguments: String

    public var id: String { label }

    init(label: String, detail: String? = nil, arguments: String = "") {
        self.label = label
        self.detail = detail
        self.arguments = arguments
    }
}

/// A change to the text, and where the caret ends up (in the changed text).
public struct LaTeXCompletionEdit: Sendable, Equatable {
    public let range: NSRange
    public let text: String
    public let selection: NSRange
}

/// Completion for the paper editor: finds what the caret is completing, offers commands,
/// environments, labels, citation keys, packages and file paths, and turns a pick into an edit
/// (closing braces, and the `\end{…}` of a new environment).
public enum LaTeXCompletion {
    public static func context(in text: String, at cursor: Int) -> LaTeXCompletionContext? {
        let string = text as NSString
        guard cursor >= 0, cursor <= string.length else { return nil }
        return commandContext(string, cursor) ?? argumentContext(string, cursor)
    }

    public static func suggestions(
        for context: LaTeXCompletionContext,
        in text: String,
        symbols: LaTeXSymbols,
        limit: Int = 40
    ) -> [LaTeXSuggestion] {
        let candidates: [LaTeXSuggestion] = switch context.kind {
        case .command:
            symbols.commands.map { LaTeXSuggestion(label: "\\" + $0, detail: symbols.commandDefinitions[$0]?.text) }
                + LaTeXCatalog.commands.map { LaTeXSuggestion(label: "\\" + $0.name, detail: $0.description, arguments: $0.arguments) }
        case .beginEnvironment:
            environmentSuggestions(symbols)
        case .endEnvironment:
            openEnvironments(in: text as NSString, before: context.range.location).reversed().map {
                LaTeXSuggestion(label: $0, detail: "Closes the open \\begin{\($0)}.")
            } + environmentSuggestions(symbols)
        case .citation:
            symbols.citations.map { LaTeXSuggestion(label: $0.key, detail: citationDetail($0)) }
        case .reference:
            symbols.labels.map { label in
                LaTeXSuggestion(label: label, detail: symbols.labelDefinitions[label].map { "\($0.file):\($0.line)" })
            }
        case .texFile:
            symbols.texFiles.map { LaTeXSuggestion(label: $0) }
        case .graphic:
            symbols.graphics.map { LaTeXSuggestion(label: $0) }
        case .bibliography(let withExtension):
            symbols.bibFiles.map { LaTeXSuggestion(label: withExtension ? $0 : ($0 as NSString).deletingPathExtension) }
        case .package:
            LaTeXCatalog.packages.map { LaTeXSuggestion(label: $0.name, detail: $0.description) }
        }
        let typed = context.kind == .command ? "\\" + context.prefix : context.prefix
        return Array(rank(candidates, typed: typed).prefix(limit))
    }

    /// The edit that puts `suggestion` in place of the word at `range` (and the rest of that word
    /// after the caret, so picking in the middle of a word replaces all of it).
    public static func edit(
        applying suggestion: LaTeXSuggestion,
        kind: LaTeXCompletionContext.Kind,
        replacing range: NSRange,
        in text: String
    ) -> LaTeXCompletionEdit {
        let string = text as NSString
        var end = NSMaxRange(range)
        let isCommand = kind == .command
        while end < string.length, let scalar = UnicodeScalar(string.character(at: end)),
              isCommand ? isCommandLetter(scalar) : !"},\n".unicodeScalars.contains(scalar) {
            end += 1
        }
        var insertion: String
        var caret: Int
        if isCommand {
            insertion = suggestion.label + suggestion.arguments
            let open = (insertion as NSString).range(of: "{").location
            caret = open == NSNotFound ? (insertion as NSString).length : open + 1
        } else {
            let next = end < string.length ? string.character(at: end) : 0
            if next == unit("}") { end += 1 }
            insertion = suggestion.label + (next == unit(",") ? "" : "}")
            caret = (insertion as NSString).length
            if kind == .beginEnvironment, !isClosed(suggestion.label, in: string, after: end) {
                let indent = indentation(of: string, at: range.location)
                let body = indent + "  " + (LaTeXCatalog.listEnvironments.contains(suggestion.label) ? "\\item " : "")
                insertion += "\n" + body
                caret = (insertion as NSString).length
                insertion += "\n" + indent + "\\end{" + suggestion.label + "}"
            }
        }
        let replaced = NSRange(location: range.location, length: end - range.location)
        return LaTeXCompletionEdit(range: replaced, text: insertion, selection: NSRange(location: range.location + caret, length: 0))
    }

    // MARK: Context

    private static func commandContext(_ string: NSString, _ cursor: Int) -> LaTeXCompletionContext? {
        var start = cursor
        while start > 0, let scalar = UnicodeScalar(string.character(at: start - 1)), isCommandLetter(scalar) { start -= 1 }
        guard start > 0, string.character(at: start - 1) == backslash, !isEscaped(string, start - 1) else { return nil }
        let range = NSRange(location: start - 1, length: cursor - start + 1)
        return LaTeXCompletionContext(kind: .command, range: range, prefix: string.substring(with: NSRange(location: start, length: cursor - start)))
    }

    private static func argumentContext(_ string: NSString, _ cursor: Int) -> LaTeXCompletionContext? {
        // Back to the `{` that opens the argument, past commas of a list, within one line.
        var index = cursor
        var wordStart: Int?
        var hasComma = false
        while index > 0, cursor - index < 300 {
            let char = string.character(at: index - 1)
            if char == unit("{") { break }
            if char == unit(",") {
                hasComma = true
                wordStart = wordStart ?? index
            }
            if [unit("}"), unit("\n"), backslash, unit("$"), unit("%")].contains(char) { return nil }
            index -= 1
        }
        guard index > 0, string.character(at: index - 1) == unit("{"),
              let command = commandName(before: index - 1, in: string),
              let kind = argumentKind(command),
              !hasComma || [.citation, .reference, .package].contains(kind) else { return nil }
        var start = wordStart ?? index
        while start < cursor, string.character(at: start) == unit(" ") { start += 1 }
        let range = NSRange(location: start, length: cursor - start)
        return LaTeXCompletionContext(kind: kind, range: range, prefix: string.substring(with: range))
    }

    /// The command whose argument opens at `brace`, past optional `[…]` arguments and a `*`.
    static func commandName(before brace: Int, in string: NSString) -> String? {
        var end = brace
        while end > 0, string.character(at: end - 1) == unit("]") {
            let open = string.range(of: "[", options: .backwards, range: NSRange(location: 0, length: end - 1))
            guard open.location != NSNotFound else { return nil }
            end = open.location
        }
        if end > 0, string.character(at: end - 1) == unit("*") { end -= 1 }
        var start = end
        while start > 0, let scalar = UnicodeScalar(string.character(at: start - 1)), isCommandLetter(scalar) { start -= 1 }
        guard start < end, start > 0, string.character(at: start - 1) == backslash else { return nil }
        return string.substring(with: NSRange(location: start, length: end - start))
    }

    static func argumentKind(_ command: String) -> LaTeXCompletionContext.Kind? {
        switch command {
        case "begin": .beginEnvironment
        case "end": .endEnvironment
        case "input", "include", "subfile", "includeonly": .texFile
        case "includegraphics": .graphic
        case "bibliography": .bibliography(withExtension: false)
        case "addbibresource": .bibliography(withExtension: true)
        case "usepackage", "RequirePackage": .package
        case _ where command.lowercased().hasSuffix("ref"): .reference
        case _ where command.lowercased().contains("cite"): .citation
        default: nil
        }
    }

    private static func environmentSuggestions(_ symbols: LaTeXSymbols) -> [LaTeXSuggestion] {
        symbols.environments.map { LaTeXSuggestion(label: $0, detail: symbols.environmentDefinitions[$0]?.text) }
            + LaTeXCatalog.environments.map { LaTeXSuggestion(label: $0.name, detail: $0.description) }
    }

    /// `Knuth (1984) — Literate Programming`.
    static func citationDetail(_ citation: LaTeXSymbols.Citation) -> String? {
        let byline = [citation.author.map(shortAuthor), citation.year.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let parts = [byline.isEmpty ? nil : byline, citation.title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    /// The first author's family name, with "et al." for more: `Knuth, Donald E. and Lamport, L.` → `Knuth et al.`
    private static func shortAuthor(_ authors: String) -> String {
        let names = authors.components(separatedBy: " and ")
        let first = names[0].trimmingCharacters(in: .whitespaces)
        let family = first.contains(",") ? String(first.split(separator: ",")[0]) : (first.split(separator: " ").last.map(String.init) ?? first)
        return names.count > 1 ? family + " et al." : family
    }

    // MARK: Ranking

    /// Case-sensitive prefix matches first (`\Delta` vs `\delta`), then any-case prefix, then
    /// substring; each in the candidates' order. Duplicates and the exact word typed are dropped.
    private static func rank(_ candidates: [LaTeXSuggestion], typed: String) -> [LaTeXSuggestion] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.label).inserted }
        guard !typed.isEmpty, typed != "\\" else { return unique }
        let lowered = typed.lowercased()
        let scored: [(score: Int, suggestion: LaTeXSuggestion)] = unique.compactMap { suggestion in
            let label = suggestion.label
            if label == typed, suggestion.arguments.isEmpty { return nil }
            if label.hasPrefix(typed) { return (0, suggestion) }
            if label.lowercased().hasPrefix(lowered) { return (1, suggestion) }
            if label.lowercased().contains(lowered.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))) { return (2, suggestion) }
            return nil
        }
        // `sorted` isn't stable; the index keeps the candidates' order within a score.
        return scored.enumerated().sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }.map(\.element.suggestion)
    }

    // MARK: Helpers

    static let backslash = unit("\\")

    private static func unit(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }

    static func isCommandLetter(_ scalar: UnicodeScalar) -> Bool {
        scalar.isASCII && (CharacterSet.letters.contains(scalar) || scalar == "@")
    }

    static func isCommandLetter(_ unit: UInt16) -> Bool {
        UnicodeScalar(unit).map(isCommandLetter) ?? false
    }

    /// Whether the backslash at `index` is the second of `\\` (a line break, not a command).
    static func isEscaped(_ string: NSString, _ index: Int) -> Bool {
        var count = 0
        var position = index - 1
        while position >= 0, string.character(at: position) == backslash {
            count += 1
            position -= 1
        }
        return count % 2 == 1
    }

    /// Environments begun and not yet ended before `location`, outermost first.
    static func openEnvironments(in string: NSString, before location: Int) -> [String] {
        var stack: [String] = []
        environmentTag.enumerateMatches(in: string as String, range: NSRange(location: 0, length: location)) { match, _, _ in
            guard let match else { return }
            let name = string.substring(with: match.range(at: 2))
            if string.substring(with: match.range(at: 1)) == "begin" {
                stack.append(name)
            } else if let last = stack.lastIndex(of: name) {
                stack.removeSubrange(last...)
            }
        }
        return stack
    }

    private static func isClosed(_ name: String, in string: NSString, after location: Int) -> Bool {
        let rest = string.substring(from: location).drop { $0.isWhitespace }
        return rest.hasPrefix("\\end{" + name + "}")
    }

    private static func indentation(of string: NSString, at location: Int) -> String {
        let line = string.lineRange(for: NSRange(location: location, length: 0))
        let text = string.substring(with: NSRange(location: line.location, length: location - line.location))
        return String(text.prefix { $0 == " " || $0 == "\t" })
    }

    private static let environmentTag = try! NSRegularExpression(pattern: #"\\(begin|end)\{([^}\n]+)\}"#)
}
