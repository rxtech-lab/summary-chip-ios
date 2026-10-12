import Foundation

/// A `\newcommand`: how many arguments it takes, the first one's default when optional, and
/// what it expands to with `#1`… in place.
struct PaperMacro: Sendable, Hashable {
    var parameters: Int
    var defaultArgument: String?
    var body: String
}

/// A `\newtheorem`: the title it prints and the counter it shares.
struct PaperTheoremKind: Sendable, Hashable {
    var title: String
    var counter: String
    var numbered: Bool
    /// `\newtheorem{lemma}{Lemma}[section]`: numbered within sections.
    var within: String?
}

extension PaperReaderParser {
    // MARK: Files

    /// The main file with its `\input`s and `\include`s inlined and comments removed.
    func assemble() -> String {
        var visiting = Set<String>()
        return inline(source.mainFile, visiting: &visiting, depth: 0)
    }

    private func inline(_ path: String, visiting: inout Set<String>, depth: Int) -> String {
        guard depth < 8, let file = texFile(path), !visiting.contains(file.path) else { return "" }
        visiting.insert(file.path)
        defer { visiting.remove(file.path) }
        let text = Self.stripComments(file.content)
        let string = text as NSString
        var result = ""
        var last = 0
        for match in Self.inputPattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            result += string.substring(with: NSRange(location: last, length: match.range.location - last))
            let target = string.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let isInclude = string.substring(with: match.range).hasPrefix("\\include")
            result += (isInclude ? "\n\n" : "") + inline(target, visiting: &visiting, depth: depth + 1) + (isInclude ? "\n\n" : "")
            last = match.range.location + match.range.length
        }
        result += string.substring(from: last)
        return result
    }

    /// A text file as `\input` names it: with or without `.tex`, from the project root.
    func texFile(_ path: String) -> PaperFile? {
        var name = path.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix("./") { name.removeFirst(2) }
        let candidates = [name, name + ".tex"]
        return candidates.lazy.compactMap { candidate in self.source.files.first { $0.path == candidate && !$0.isImage } }.first
    }

    private static let inputPattern = try! NSRegularExpression(pattern: #"\\(?:input|include|subfile)\s*\{([^}]*)\}"#)

    /// Removes `%` comments, except inside verbatim environments. A line holding only a comment
    /// goes entirely, so it neither ends a paragraph nor joins two.
    static func stripComments(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var verbatimEnd: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let end = verbatimEnd {
                result += line + "\n"
                if line.contains(end) { verbatimEnd = nil }
                continue
            }
            if let begin = verbatimEnvironments.first(where: { line.contains("\\begin{\($0)}") }) {
                verbatimEnd = line.contains("\\end{\(begin)}") ? nil : "\\end{\(begin)}"
                result += line + "\n"
                continue
            }
            guard let comment = commentStart(line) else {
                result += line + "\n"
                continue
            }
            let kept = line[..<comment]
            if kept.allSatisfy({ $0 == " " || $0 == "\t" }) { continue }
            result += kept + "\n"
        }
        if !text.hasSuffix("\n"), result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    static let verbatimEnvironments = ["verbatim", "verbatim*", "Verbatim", "lstlisting", "minted", "comment", "alltt"]

    private static func commentStart(_ line: Substring) -> Substring.Index? {
        var backslashes = 0
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if c == "%", backslashes % 2 == 0 { return index }
            backslashes = c == "\\" ? backslashes + 1 : 0
            index = line.index(after: index)
        }
        return nil
    }

    // MARK: Definitions

    /// Collects and removes `\newcommand`s, `\def`s, `\DeclareMathOperator`s, `\newtheorem`s and
    /// `\newenvironment`s, leaving the rest of the text as it was.
    func collectDefinitions(_ text: String) -> String {
        chars = Array(text)
        pos = 0
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        while !isAtEnd {
            guard chars[pos] == "\\" else {
                result.append(chars[pos])
                pos += 1
                continue
            }
            let start = pos
            pos += 1
            let name = readLetters()
            switch name {
            case "newcommand", "renewcommand", "providecommand", "DeclareRobustCommand": defineCommand()
            case "def", "gdef", "edef", "xdef": defineDef()
            case "DeclareMathOperator": defineOperator()
            case "newtheorem": defineTheorem()
            case "newenvironment", "renewenvironment":
                _ = readStar()
                _ = readGroup()
                _ = readOptional()
                _ = readOptional()
                _ = readGroup()
                _ = readGroup()
            default:
                result.append(contentsOf: chars[start..<pos])
            }
        }
        return String(result)
    }

    private func defineCommand() {
        _ = readStar()
        skipSpaces()
        let name: String
        if let group = readGroup() {
            name = group.trimmingCharacters(in: .whitespaces)
        } else if !isAtEnd, chars[pos] == "\\" {
            pos += 1
            name = "\\" + readLetters()
        } else {
            return
        }
        let parameters = readOptional().flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let defaultArgument = readOptional()
        guard let body = readGroup(), name.hasPrefix("\\"), name.count > 1 else { return }
        macros[String(name.dropFirst())] = PaperMacro(parameters: parameters, defaultArgument: defaultArgument, body: body)
    }

    private func defineDef() {
        skipSpaces()
        guard !isAtEnd, chars[pos] == "\\" else { return }
        pos += 1
        let name = readLetters()
        var parameters = 0
        while !isAtEnd, chars[pos] != "{" {
            if chars[pos] == "#" { parameters += 1 }
            pos += 1
        }
        guard let body = readGroup(), !name.isEmpty else { return }
        macros[name] = PaperMacro(parameters: parameters, defaultArgument: nil, body: body)
    }

    private func defineOperator() {
        let starred = readStar()
        guard let rawName = readGroup(), let body = readGroup() else { return }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\\ "))
        macros[name] = PaperMacro(parameters: 0, defaultArgument: nil, body: "\\operatorname\(starred ? "*" : ""){\(body)}")
    }

    private func defineTheorem() {
        let starred = readStar()
        guard let name = readGroup() else { return }
        let shared = readOptional()
        guard let title = readGroup() else { return }
        let within = readOptional()
        let counter = shared?.trimmingCharacters(in: .whitespaces) ?? name
        theoremKinds[name] = PaperTheoremKind(title: title, counter: counter, numbered: !starred, within: within ?? theoremKinds[counter]?.within)
    }

    // MARK: Macros

    /// The text with the paper's own commands expanded.
    func expandMacros(_ text: String) -> String {
        guard !macros.isEmpty else { return text }
        return expand(Array(text), depth: 0)
    }

    private func expand(_ text: [Character], depth: Int) -> String {
        guard depth < 12 else { return String(text) }
        let saved = (chars, pos)
        defer { (chars, pos) = saved }
        chars = text
        pos = 0
        var result: [Character] = []
        result.reserveCapacity(text.count)
        while !isAtEnd {
            let c = chars[pos]
            guard c == "\\", pos + 1 < chars.count else {
                result.append(c)
                pos += 1
                continue
            }
            if !chars[pos + 1].isLetter {
                result.append(c)
                result.append(chars[pos + 1])
                pos += 2
                continue
            }
            let start = pos
            pos += 1
            let name = readLetters()
            guard let macro = macros[name] else {
                result.append(contentsOf: chars[start..<pos])
                continue
            }
            var arguments: [String] = []
            if macro.parameters > 0 {
                if let defaultArgument = macro.defaultArgument { arguments.append(readOptional() ?? defaultArgument) }
                while arguments.count < macro.parameters { arguments.append(readArgument()) }
            }
            var body = macro.body
            for (index, argument) in arguments.enumerated().reversed() {
                body = body.replacingOccurrences(of: "#\(index + 1)", with: argument)
            }
            let expanded = expand(Array(body), depth: depth + 1)
            result.append(contentsOf: expanded)
        }
        return String(result)
    }
}
