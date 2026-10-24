import Foundation

/// One `@article{key, …}` from a `.bib` file, its field values as written.
struct BibRecord: Sendable, Hashable {
    var type: String
    var key: String
    var fields: [String: String]
}

extension PaperReaderParser {
    /// Numbers the cited entries the way the paper's style orders them: by first citation for
    /// `unsrt`-like styles, else by author, year and title.
    func finishBibliography() {
        var entries: [PaperBibEntry] = []
        if !bibItems.isEmpty {
            entries = bibItems.enumerated().map { index, item in
                PaperBibEntry(key: item.key, number: index + 1, text: Self.trimmed(parseInline(item.raw, style: [])), shortAuthor: nil, year: nil, url: nil)
            }
        } else {
            let records = bibliographyFiles().flatMap { Self.bibRecords($0.content) }
            var byKey: [String: BibRecord] = [:]
            for record in records where byKey[record.key] == nil { byKey[record.key] = record }
            var keys = citationOrder.filter { byKey[$0] != nil }
            if citesEverything {
                keys += records.map(\.key).filter { !keys.contains($0) }
            }
            var cited = keys.compactMap { byKey[$0] }
            if !isUnsorted {
                cited.sort { Self.sortKey($0) < Self.sortKey($1) }
            }
            entries = cited.enumerated().map { index, record in entry(record, number: index + 1) }
        }
        document.bibliography = entries
        document.citationNumbers = Dictionary(entries.map { ($0.key, $0.number) }, uniquingKeysWith: { first, _ in first })
    }

    private var isUnsorted: Bool {
        if biblatexUnsorted { return true }
        let style = (bibliographyStyle ?? "").lowercased()
        return ["unsrt", "ieee", "nature", "vancouver", "apsrev", "elsarticle-num", "splncs", "abbrvunsrt"].contains { style.contains($0) }
    }

    /// The `.bib` files `\bibliography` or `\addbibresource` name, or every one when none is named.
    private func bibliographyFiles() -> [PaperFile] {
        let bibs = source.files.filter { $0.fileExtension == "bib" }
        guard !bibFiles.isEmpty else { return bibs }
        return bibFiles.compactMap { name in
            var name = name.trimmingCharacters(in: .whitespaces)
            while name.hasPrefix("./") { name.removeFirst(2) }
            return bibs.first { $0.path == name || $0.path == name + ".bib" }
        }
    }

    private static func sortKey(_ record: BibRecord) -> String {
        let author = names(record.fields["author"] ?? record.fields["editor"] ?? "").first.map(lastName) ?? record.key
        return [author, record.fields["year"] ?? "", record.fields["title"] ?? ""].joined(separator: "\u{1}").lowercased()
    }

    // MARK: Formatting

    /// `D. E. Knuth. The TeXbook. Addison-Wesley, 1984.`, with the field markup read as LaTeX.
    private func entry(_ record: BibRecord, number: Int) -> PaperBibEntry {
        let fields = record.fields
        let authors = Self.names(fields["author"] ?? fields["editor"] ?? "")
        var parts: [String] = []
        if !authors.isEmpty { parts.append(Self.joinedNames(authors.map(Self.displayName))) }
        let isBook = ["book", "phdthesis", "mastersthesis", "manual", "booklet", "proceedings"].contains(record.type)
        if let title = fields["title"] { parts.append(isBook ? "\\emph{\(title)}" : title) }
        var venue: [String] = []
        if let container = fields["journal"] ?? fields["journaltitle"] ?? fields["booktitle"] {
            venue.append((record.type == "inproceedings" || record.type == "incollection" ? "In " : "") + "\\emph{\(container)}")
        }
        if let volume = fields["volume"] { venue.append(volume + (fields["number"].map { "(\($0))" } ?? "")) }
        if let pages = fields["pages"] { venue.append((venue.isEmpty ? "pp. " : "") + pages) }
        if let publisher = fields["publisher"] ?? fields["school"] ?? fields["institution"] ?? fields["organization"] { venue.append(publisher) }
        if let howPublished = fields["howpublished"] { venue.append(howPublished) }
        let year = fields["year"] ?? fields["date"].map { String($0.prefix(4)) }
        if let year { venue.append(year) }
        if !venue.isEmpty { parts.append(venue.joined(separator: ", ")) }
        let text = parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
        let url = fields["url"] ?? fields["doi"].map { $0.hasPrefix("http") ? $0 : "https://doi.org/" + $0 }
        let shortAuthor = authors.isEmpty ? nil : Self.shortAuthor(authors).map { Self.trimmed(parseInline($0, style: [])).plainText }
        return PaperBibEntry(
            key: record.key, number: number, text: Self.trimmed(parseInline(text, style: [])),
            shortAuthor: shortAuthor, year: year.map { Self.trimmed(parseInline($0, style: [])).plainText }, url: url
        )
    }

    /// `Knuth, Donald and Lamport, Leslie` → each name, split at top-level ` and `.
    static func names(_ field: String) -> [String] {
        var names: [String] = []
        var depth = 0
        var current = ""
        let words = field.replacingOccurrences(of: "\n", with: " ").split(separator: " ", omittingEmptySubsequences: true)
        for word in words {
            if depth == 0, word.lowercased() == "and" {
                names.append(current)
                current = ""
                continue
            }
            depth += word.filter { $0 == "{" }.count - word.filter { $0 == "}" }.count
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty { names.append(current) }
        return names
    }

    static func lastName(_ name: String) -> String {
        if let comma = name.firstIndex(of: ",") { return String(name[..<comma]).trimmingCharacters(in: .whitespaces) }
        return name.split(separator: " ").last.map(String.init) ?? name
    }

    /// `Knuth, Donald E.` → `Donald E. Knuth`.
    private static func displayName(_ name: String) -> String {
        let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? "\(parts[1]) \(parts[0])" : name
    }

    private static func joinedNames(_ names: [String]) -> String {
        var names = names
        let others = names.last == "others"
        if others { names.removeLast() }
        guard !others else { return names.joined(separator: ", ") + " et al" }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    /// What `\citet` names: `Knuth`, `Knuth and Lamport`, `Knuth et al.`
    private static func shortAuthor(_ names: [String]) -> String? {
        guard let first = names.first.map(lastName) else { return nil }
        if names.count == 2, names[1] != "others" { return "\(first) and \(lastName(names[1]))" }
        return names.count > 1 ? "\(first) et al." : first
    }

    // MARK: Parsing

    /// The entries of a `.bib` file; `@string` abbreviations are expanded.
    static func bibRecords(_ text: String) -> [BibRecord] {
        var scanner = BibRecordScanner(chars: Array(text))
        return scanner.records()
    }
}

private struct BibRecordScanner {
    let chars: [Character]
    var index = 0
    var strings: [String: String] = [:]

    mutating func records() -> [BibRecord] {
        var records: [BibRecord] = []
        while index < chars.count {
            guard chars[index] == "@" else { index += 1; continue }
            index += 1
            let type = word().lowercased()
            skipSpaces()
            guard index < chars.count, chars[index] == "{" || chars[index] == "(" else { continue }
            let close: Character = chars[index] == "{" ? "}" : ")"
            index += 1
            if type == "comment" || type == "preamble" { _ = balanced(close); continue }
            skipSpaces()
            var key = ""
            if type != "string" {
                while index < chars.count, chars[index] != ",", chars[index] != close { key.append(chars[index]); index += 1 }
                key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var fields: [String: String] = [:]
            while index < chars.count {
                skipSpaces()
                if index < chars.count, chars[index] == "," { index += 1; continue }
                if index >= chars.count || chars[index] == close { index += 1; break }
                let name = word().lowercased()
                skipSpaces()
                guard !name.isEmpty, index < chars.count, chars[index] == "=" else { index += 1; continue }
                index += 1
                fields[name] = value().replacingOccurrences(of: "\n", with: " ")
            }
            if type == "string" {
                for (name, text) in fields { strings[name] = text }
            } else if !key.isEmpty {
                records.append(BibRecord(type: type, key: key, fields: fields))
            }
        }
        return records
    }

    private mutating func skipSpaces() { while index < chars.count, chars[index].isWhitespace { index += 1 } }
    private mutating func word() -> String {
        var result = ""
        while index < chars.count, chars[index].isLetter || chars[index].isNumber || "-_:./+'".contains(chars[index]) {
            result.append(chars[index])
            index += 1
        }
        return result
    }

    private mutating func balanced(_ close: Character) -> String {
        var depth = 0
        var result = ""
        while index < chars.count {
            let c = chars[index]
            index += 1
            if c == "\\", index < chars.count { result.append(c); result.append(chars[index]); index += 1; continue }
            if c == "{" { depth += 1 } else if c == "}" { if depth == 0, close == "}" { break }; depth -= 1 }
            if c == close, depth == 0, close != "}" { break }
            result.append(c)
        }
        return result
    }

    private mutating func value() -> String {
        var result = ""
        repeat {
            skipSpaces()
            guard index < chars.count else { break }
            switch chars[index] {
            case "{": index += 1; result += balanced("}")
            case "\"": index += 1; result += balanced("\"")
            default: let bare = word(); result += strings[bare.lowercased()] ?? bare
            }
            skipSpaces()
            guard index < chars.count, chars[index] == "#" else { break }
            index += 1
        } while true
        return result
    }
}
