import Compression
import Foundation
import UniformTypeIdentifiers

/// Reads the text of Office Open XML (Excel, PowerPoint, Word) and OpenDocument files on this
/// device. Both are ZIP packages of XML, so no Office installation or server upload is needed.
enum OfficeDocument {
    static let spreadsheetExtensions = ["xlsx", "xlsm", "ods"]
    static let presentationExtensions = ["pptx", "pptm", "odp"]
    static let wordExtensions = ["docx", "docm", "odt"]
    static var extensions: [String] { spreadsheetExtensions + presentationExtensions + wordExtensions }

    static let typeIdentifiers = [
        "org.openxmlformats.spreadsheetml.sheet", "org.openxmlformats.spreadsheetml.sheet.macroenabled",
        "org.openxmlformats.presentationml.presentation", "org.openxmlformats.presentationml.presentation.macroenabled",
        "org.openxmlformats.wordprocessingml.document", "org.openxmlformats.wordprocessingml.document.macroenabled",
        "org.oasis-open.opendocument.spreadsheet", "org.oasis-open.opendocument.presentation",
        "org.oasis-open.opendocument.text",
    ]

    static var contentTypes: [UTType] { typeIdentifiers.compactMap { UTType($0) } }

    static func isOfficeType(_ type: UTType) -> Bool {
        contentTypes.contains(where: type.conforms(to:))
    }

    /// The document's text, at most `limit` UTF-16 code units; longer documents are read from their opening.
    static func text(at url: URL, limit: Int) throws -> String {
        let archive = try ZipArchive(data: Data(contentsOf: url, options: .mappedIfSafe))
        let ext = url.pathExtension.lowercased()
        let text: String
        if archive.contains("content.xml") {
            text = OpenDocumentText.read(try archive.data(for: "content.xml"), limit: limit)
        } else if spreadsheetExtensions.contains(ext) || archive.contains("xl/workbook.xml") {
            text = try spreadsheet(archive, limit: limit)
        } else if presentationExtensions.contains(ext) || archive.contains("ppt/presentation.xml") {
            text = try presentation(archive, limit: limit)
        } else if archive.contains("word/document.xml") {
            text = XMLRunText.read(try archive.data(for: "word/document.xml"), limit: limit)
        } else {
            throw LocalDocumentError.unsupported
        }
        // Drop trailing cell separators and collapse the blank lines empty rows and slides leave.
        let tidy = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/[ \t]+$/, with: "") }
            .joined(separator: "\n")
            .replacing(/\n{3,}/, with: "\n\n")
        return LocalDocument.prefix(tidy.trimmingCharacters(in: .whitespacesAndNewlines), utf16Length: limit)
    }

    /// Each sheet as a heading followed by tab-separated rows.
    private static func spreadsheet(_ archive: ZipArchive, limit: Int) throws -> String {
        let shared = archive.contains("xl/sharedStrings.xml")
            ? SharedStrings.read(try archive.data(for: "xl/sharedStrings.xml")) : []
        var sheets = archive.contains("xl/workbook.xml")
            ? WorkbookSheets.read(workbook: try archive.data(for: "xl/workbook.xml"),
                                  relationships: archive.contains("xl/_rels/workbook.xml.rels") ? try archive.data(for: "xl/_rels/workbook.xml.rels") : nil)
            : []
        sheets = sheets.filter { archive.contains($0.path) }
        if sheets.isEmpty {
            sheets = numbered(archive.paths, prefix: "xl/worksheets/sheet").enumerated()
                .map { (name: "Sheet \($0.offset + 1)", path: $0.element) }
        }
        var output = ""
        for sheet in sheets {
            let remaining = limit - output.utf16.count
            guard remaining > 0 else { break }
            let rows = SheetRows.read(try archive.data(for: sheet.path), sharedStrings: shared, limit: remaining)
            guard !rows.isEmpty else { continue }
            output += "## \(sheet.name)\n\(rows)\n\n"
        }
        return output
    }

    /// Each slide's text, in slide order.
    private static func presentation(_ archive: ZipArchive, limit: Int) throws -> String {
        var output = ""
        for (index, path) in numbered(archive.paths, prefix: "ppt/slides/slide").enumerated() {
            let remaining = limit - output.utf16.count
            guard remaining > 0 else { break }
            let text = XMLRunText.read(try archive.data(for: path), limit: remaining)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            output += "## Slide \(index + 1)\n\(text)\n\n"
        }
        return output
    }

    /// Paths like `prefix12.xml`, ordered by their number.
    private static func numbered(_ paths: [String], prefix: String) -> [String] {
        paths.compactMap { path -> (Int, String)? in
            guard path.hasPrefix(prefix), path.hasSuffix(".xml"),
                  let number = Int(path.dropFirst(prefix.count).dropLast(4)) else { return nil }
            return (number, path)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }
}

// MARK: - ZIP

/// A minimal ZIP reader for stored and deflated entries, which is all Office packages use.
struct ZipArchive {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    /// Guards against ZIP bombs: no single part of a document is expected to be this large.
    static let maxEntrySize = 200 * 1024 * 1024

    private let bytes: [UInt8]
    private let entries: [String: Entry]
    let paths: [String]

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw LocalDocumentError.unsupported }
        // The end-of-central-directory record is within the last 64 KB (its comment is at most 65,535 bytes).
        var end = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while end >= floor, Self.uint32(bytes, end) != 0x0605_4B50 { end -= 1 }
        guard end >= floor else { throw LocalDocumentError.unsupported }
        let count = Int(Self.uint16(bytes, end + 10))
        var offset = Int(Self.uint32(bytes, end + 16))
        var entries: [String: Entry] = [:]
        var paths: [String] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, Self.uint32(bytes, offset) == 0x0201_4B50 else {
                throw LocalDocumentError.unsupported
            }
            let nameLength = Int(Self.uint16(bytes, offset + 28))
            let extraLength = Int(Self.uint16(bytes, offset + 30))
            let commentLength = Int(Self.uint16(bytes, offset + 32))
            guard offset + 46 + nameLength <= bytes.count else { throw LocalDocumentError.unsupported }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(
                method: Self.uint16(bytes, offset + 10),
                compressedSize: Int(Self.uint32(bytes, offset + 20)),
                size: Int(Self.uint32(bytes, offset + 24)),
                localHeaderOffset: Int(Self.uint32(bytes, offset + 42))
            )
            paths.append(name)
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
        self.paths = paths
    }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    func data(for path: String) throws -> Data {
        guard let entry = entries[path], entry.size <= Self.maxEntrySize else { throw LocalDocumentError.unsupported }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.uint32(bytes, header) == 0x0403_4B50 else {
            throw LocalDocumentError.unsupported
        }
        let start = header + 30 + Int(Self.uint16(bytes, header + 26)) + Int(Self.uint16(bytes, header + 28))
        guard start + entry.compressedSize <= bytes.count else { throw LocalDocumentError.unsupported }
        let compressed = bytes[start..<(start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            guard entry.size > 0 else { return Data() }
            var output = [UInt8](repeating: 0, count: entry.size)
            // COMPRESSION_ZLIB decodes raw DEFLATE, as stored in ZIP entries.
            let written = compressed.withUnsafeBufferPointer { source in
                compression_decode_buffer(&output, entry.size, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
            guard written == entry.size else { throw LocalDocumentError.unsupported }
            return Data(output)
        default:
            throw LocalDocumentError.unsupported
        }
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

// MARK: - XML

/// Base for the parsers below: elements arrive by local name, and parsing stops at the limit.
private class TextParser: NSObject, XMLParserDelegate {
    var output = ""
    private var outputLength = 0
    let limit: Int
    private(set) var path: [String] = []

    init(limit: Int) { self.limit = limit }

    func run(_ data: Data) -> String {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        return output
    }

    func append(_ text: String, _ parser: XMLParser) {
        output += text
        outputLength += text.utf16.count
        if outputLength > limit { parser.abortParsing() }
    }

    func start(_ name: String, attributes: [String: String], _ parser: XMLParser) {}
    func end(_ name: String, _ parser: XMLParser) {}
    func text(_ string: String, _ parser: XMLParser) {}

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(elementName)
        // Attributes keep their prefixes (`r:id`, `text:c`); match them by local name.
        let local = Dictionary(attributes.map { (String($0.key.split(separator: ":").last ?? ""), $0.value) }) { first, _ in first }
        start(elementName, attributes: local, parser)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        end(elementName, parser)
        path.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text(string, parser)
    }
}

/// Word and PowerPoint text: runs (`<w:t>`, `<a:t>`) inside paragraphs (`<w:p>`, `<a:p>`).
private final class XMLRunText: TextParser {
    static func read(_ data: Data, limit: Int) -> String {
        XMLRunText(limit: limit).run(data)
    }

    override func start(_ name: String, attributes: [String: String], _ parser: XMLParser) {
        switch name {
        case "tab": append("\t", parser)
        case "br", "cr": append("\n", parser)
        default: break
        }
    }

    override func end(_ name: String, _ parser: XMLParser) {
        if name == "p" { append("\n", parser) }
    }

    override func text(_ string: String, _ parser: XMLParser) {
        if path.last == "t" { append(string, parser) }
    }
}

/// OpenDocument `content.xml`: paragraphs and headings, with table cells tab-separated.
private final class OpenDocumentText: TextParser {
    static func read(_ data: Data, limit: Int) -> String {
        OpenDocumentText(limit: limit).run(data)
    }

    private var paragraphDepth = 0
    private var cellHasParagraph = false

    override func start(_ name: String, attributes: [String: String], _ parser: XMLParser) {
        switch name {
        case "table-cell": cellHasParagraph = false
        case "p", "h":
            paragraphDepth += 1
            // Paragraphs inside a cell are separated by a space so the row stays on one line.
            if path.contains("table-cell") {
                if cellHasParagraph { append(" ", parser) }
                cellHasParagraph = true
            }
        case "s": append(String(repeating: " ", count: Int(attributes["c"] ?? "") ?? 1), parser)
        case "tab": append("\t", parser)
        case "line-break": append("\n", parser)
        default: break
        }
    }

    override func end(_ name: String, _ parser: XMLParser) {
        switch name {
        case "p", "h":
            paragraphDepth -= 1
            if !path.contains("table-cell") { append("\n", parser) }
        case "table-cell": append("\t", parser)
        case "table-row": append("\n", parser)
        case "table": append("\n", parser)
        default: break
        }
    }

    override func text(_ string: String, _ parser: XMLParser) {
        if paragraphDepth > 0 { append(string, parser) }
    }
}

/// `xl/sharedStrings.xml`: the strings cells refer to by index. Phonetic hints are skipped.
private final class SharedStrings: TextParser {
    static func read(_ data: Data) -> [String] {
        let parser = SharedStrings(limit: .max)
        _ = parser.run(data)
        return parser.strings
    }

    private(set) var strings: [String] = []

    override func end(_ name: String, _ parser: XMLParser) {
        if name == "si" {
            strings.append(output)
            output = ""
        }
    }

    override func text(_ string: String, _ parser: XMLParser) {
        if path.last == "t", !path.contains("rPh") { output += string }
    }
}

/// Sheet names in workbook order, resolved to their part paths.
private final class WorkbookSheets: TextParser {
    static func read(workbook: Data, relationships: Data?) -> [(name: String, path: String)] {
        let parser = WorkbookSheets(limit: .max)
        if let relationships { _ = parser.run(relationships) }
        _ = parser.run(workbook)
        return parser.sheets.compactMap { sheet in
            guard let target = parser.targets[sheet.id] else { return nil }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            return (sheet.name, path)
        }
    }

    private var targets: [String: String] = [:]
    private var sheets: [(name: String, id: String)] = []

    override func start(_ name: String, attributes: [String: String], _ parser: XMLParser) {
        if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        } else if name == "sheet", let sheetName = attributes["name"], let id = attributes["id"] {
            sheets.append((sheetName, id))
        }
    }
}

/// A worksheet's rows as tab-separated lines, with blank cells kept so columns line up.
private final class SheetRows: TextParser {
    static func read(_ data: Data, sharedStrings: [String], limit: Int) -> String {
        let parser = SheetRows(limit: limit)
        parser.sharedStrings = sharedStrings
        return parser.run(data).trimmingCharacters(in: .newlines)
    }

    private var sharedStrings: [String] = []
    private var row: [String] = []
    private var cellType = ""
    private var cellColumn: Int?
    private var value = ""

    override func start(_ name: String, attributes: [String: String], _ parser: XMLParser) {
        switch name {
        case "row": row = []
        case "c":
            cellType = attributes["t"] ?? "n"
            cellColumn = attributes["r"].flatMap(Self.column)
            value = ""
        default: break
        }
    }

    override func text(_ string: String, _ parser: XMLParser) {
        guard path.contains("c"), !path.contains("rPh") else { return }
        if path.last == "v" || path.last == "t" { value += string }
    }

    override func end(_ name: String, _ parser: XMLParser) {
        switch name {
        case "c":
            var text = value
            if cellType == "s" { text = Int(value).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? "" }
            if cellType == "b" { text = value == "1" ? "TRUE" : "FALSE" }
            text = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            if let cellColumn, cellColumn > row.count, cellColumn - row.count < 1_000 {
                row += Array(repeating: "", count: cellColumn - row.count)
            }
            row.append(text)
        case "row":
            while row.last?.isEmpty == true { row.removeLast() }
            if !row.isEmpty { append(row.joined(separator: "\t") + "\n", parser) }
        default: break
        }
    }

    /// The zero-based column of a cell reference such as `C5`.
    private static func column(_ reference: String) -> Int? {
        var column = 0
        for scalar in reference.unicodeScalars {
            guard let letter = Character(scalar).asciiValue, (65...90).contains(letter) else { break }
            column = column * 26 + Int(letter - 64)
        }
        return column > 0 ? column - 1 : nil
    }
}
