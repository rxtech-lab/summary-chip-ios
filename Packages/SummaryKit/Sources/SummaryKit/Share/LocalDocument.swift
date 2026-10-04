import Foundation
import PDFKit
import UniformTypeIdentifiers

public enum LocalDocumentError: LocalizedError {
    case unsupported
    case empty
    case noPDFText
    case textTooLong
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Choose a PDF, document, spreadsheet, presentation, text, Markdown or code file.", bundle: .module)
        case .empty: String(localized: "This file is empty.", bundle: .module)
        case .noPDFText: String(localized: "This PDF has no selectable text. Scanned PDFs can't be read on this device.", bundle: .module)
        case .textTooLong: String(localized: "Text files must contain at most 200,000 characters.", bundle: .module)
        case .unavailable: String(localized: "The local file is unavailable. Choose it again in Files to restore access.", bundle: .module)
        }
    }
}

/// The text of a file read on this device. Only this text is sent to summarise; the server
/// keeps the summary but never the content, and the file stays where it is.
public struct LocalFileSource: Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case pdf, text }

    public var filename: String
    public var kind: Kind
    public var text: String

    public init(filename: String, kind: Kind, text: String) {
        self.filename = filename
        self.kind = kind
        self.text = text
    }

    /// What the file is, for display: "Markdown", "Swift source", "Word document"…
    public var typeLabel: String {
        if kind == .pdf { return String(localized: "PDF", bundle: .module) }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if LocalDocument.markdownExtensions.contains(ext) { return String(localized: "Markdown", bundle: .module) }
        guard let type = UTType(filenameExtension: ext) else { return String(localized: "Text file", bundle: .module) }
        if LocalDocument.richTextTypes.contains(where: type.conforms(to:)) {
            return type.localizedDescription ?? String(localized: "Document", bundle: .module)
        }
        if type.conforms(to: .sourceCode) || LocalDocument.codeExtensions.contains(ext) {
            return type.localizedDescription ?? String(localized: "Code", bundle: .module, comment: "File type label: source code")
        }
        return type.conforms(to: .plainText) ? String(localized: "Text file", bundle: .module) : type.localizedDescription ?? String(localized: "Text file", bundle: .module)
    }
}

/// Coordinates reads from Files providers, including iCloud downloads, while access is held.
public enum LocalDocument {
    public static var contentTypes: [UTType] {
        var types: [UTType] = [.pdf, .text, .sourceCode, .json, .yaml, .commaSeparatedText, .tabSeparatedText, .log]
        types += richTextTypes
        types += OfficeDocument.contentTypes
        // Code that the system doesn't type as text (or types as something else, like `.ts`).
        types += (markdownExtensions + codeExtensions).compactMap { UTType(filenameExtension: $0) }
        var seen = Set<UTType>()
        return types.filter { seen.insert($0).inserted }
    }

    /// The server's JavaScript limit counts UTF-16 code units.
    public static let maxTextLength = 200_000

    static let markdownExtensions = ["md", "markdown", "mdown", "mkd", "mdx"]
    static let codeExtensions = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "scala", "go", "rs",
        "py", "rb", "php", "pl", "lua", "r", "dart", "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte",
        "css", "scss", "sass", "less", "html", "htm", "xml", "json", "jsonc", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "env", "sql", "graphql", "gql", "proto", "sh", "bash", "zsh", "fish", "ps1", "bat",
        "gradle", "cmake", "make", "mk", "dockerfile", "tf", "hcl", "ex", "exs", "erl", "hs", "clj", "elm",
        "zig", "nim", "jl", "tex", "bib", "rst", "adoc", "org", "txt", "text", "log", "csv", "tsv", "srt", "vtt",
        "ipynb", "patch", "diff",
    ]

    /// Formats `NSAttributedString` converts to text on this device.
    static var richTextTypes: [UTType] {
        var types: [UTType] = [.rtf, .rtfd, .flatRTFD]
        #if os(macOS)
        // AppKit's text system also reads Word and OpenDocument files.
        types += ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                  "org.oasis-open.opendocument.text", "com.microsoft.word.wordml"].compactMap { UTType($0) }
        types.append(.webArchive)
        #endif
        return types
    }

    /// Types that are never text, rejected without reading them.
    private static let binaryTypes: [UTType] = [.archive, .image, .audiovisualContent, .executable, .font, .diskImage]

    public static func input(fileURL: URL, filename: String? = nil) throws -> SummaryInput {
        .localFile(try read(fileURL: fileURL, filename: filename))
    }

    /// Whether a file of this type identifier may be read by `read(fileURL:)`, for share and drop providers.
    public static func isReadable(typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .text) || richTextTypes.contains(where: type.conforms(to:))
            || OfficeDocument.isOfficeType(type)
    }

    /// Whether a file with this extension is one `read(fileURL:)` reads.
    public static func isReadable(extension ext: String) -> Bool {
        let ext = ext.lowercased()
        if ext == "pdf" || markdownExtensions.contains(ext) || codeExtensions.contains(ext)
            || OfficeDocument.extensions.contains(ext) { return true }
        return UTType(filenameExtension: ext).map { isReadable(typeIdentifier: $0.identifier) } ?? false
    }

    /// Reads a file that is already accessible (a staged copy, or inside a security scope).
    public static func read(fileURL: URL, filename: String? = nil) throws -> LocalFileSource {
        let name = filename ?? fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let isKnownText = markdownExtensions.contains(ext) || codeExtensions.contains(ext) || type?.conforms(to: .text) == true
        if !isKnownText, ext != "pdf", let type, binaryTypes.contains(where: type.conforms(to:)) {
            throw LocalDocumentError.unsupported
        }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? directorySize(fileURL)
        guard size > 0 else { throw LocalDocumentError.empty }
        guard size <= SummaryAPIClient.maxUploadBytes else {
            throw SummaryAPIError.fileTooLarge(maxBytes: SummaryAPIClient.maxUploadBytes)
        }
        if ext == "pdf" {
            guard let document = PDFDocument(url: fileURL) else { throw LocalDocumentError.unsupported }
            let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LocalDocumentError.noPDFText }
            // Long PDFs are summarised from their opening, as the server would after extraction.
            return LocalFileSource(filename: name, kind: .pdf, text: prefix(text, utf16Length: maxTextLength))
        }
        // HTML is read as its source: AppKit/UIKit HTML import needs WebKit on the main thread.
        if let type, type.conforms(to: .html) == false, richTextTypes.contains(where: type.conforms(to:)) {
            let document = try? NSAttributedString(url: fileURL, options: [:], documentAttributes: nil)
            guard let document else { throw LocalDocumentError.unsupported }
            let text = document.string
                .replacingOccurrences(of: "\u{FFFC}", with: "") // attachment placeholders
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LocalDocumentError.empty }
            // Like PDFs, long documents are summarised from their opening.
            return LocalFileSource(filename: name, kind: .text, text: prefix(text, utf16Length: maxTextLength))
        }
        // Spreadsheets, presentations (and Word documents on iOS) are read from their XML parts.
        if OfficeDocument.extensions.contains(ext) || type.map(OfficeDocument.isOfficeType) == true {
            let text = try OfficeDocument.text(at: fileURL, limit: maxTextLength)
            guard !text.isEmpty else { throw LocalDocumentError.empty }
            return LocalFileSource(filename: name, kind: .text, text: text)
        }
        let text = try decodeText(at: fileURL, trusted: isKnownText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalDocumentError.empty }
        guard text.utf16.count <= maxTextLength else { throw LocalDocumentError.textTooLong }
        return LocalFileSource(filename: name, kind: .text, text: text)
    }

    /// Decodes a text file. Files of unknown type (no or an unregistered extension) are read only
    /// when they look like text, so arbitrary binaries are rejected rather than summarised as noise.
    static func decodeText(at url: URL, trusted: Bool) throws -> String {
        let data = try Data(contentsOf: url)
        if !trusted, !looksLikeText(data) { throw LocalDocumentError.unsupported }
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) { return text }
        guard trusted, looksLikeText(data) else { throw LocalDocumentError.unsupported }
        return String(decoding: data, as: UTF8.self)
    }

    /// Text has no NUL bytes and few control characters other than tab, newline and form feed.
    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(8_192)
        guard !sample.isEmpty, !sample.contains(0) else { return false }
        let controls = sample.filter { $0 < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains($0) }.count
        return controls * 100 <= sample.count
    }

    /// The size of a package document such as `.rtfd`, which has no file size of its own.
    private static func directorySize(_ url: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)
    }

    /// Reads the file linked to a summary on this device, e.g. to ground a chat about it.
    public static func readLinked(summaryID: String, store: LocalFileStore = LocalFileStore()) throws -> LocalFileSource {
        let link = try store.resolve(summaryID: summaryID)
        let copy = try copyForReading(link)
        defer { discardCopy(copy) }
        do {
            return try read(fileURL: copy, filename: store.link(summaryID: summaryID)?.filename)
        } catch LocalDocumentError.textTooLong {
            // Chat only needs as much as the model reads; an edited file may have grown.
            var encoding = String.Encoding.utf8
            let text = try String(contentsOf: copy, usedEncoding: &encoding)
            return LocalFileSource(filename: copy.lastPathComponent, kind: .text, text: prefix(text, utf16Length: maxTextLength))
        }
    }

    static func prefix(_ text: String, utf16Length limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var count = 0
        let end = text.firstIndex { character in
            count += character.utf16.count
            return count > limit
        } ?? text.endIndex
        return String(text[..<end])
    }

    public static func copyForReading(_ url: URL, filename: String? = nil) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copied: Result<URL, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            copied = Result {
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= SummaryAPIClient.maxUploadBytes else {
                    throw SummaryAPIError.fileTooLarge(maxBytes: SummaryAPIClient.maxUploadBytes)
                }
                let directory = FileManager.default.temporaryDirectory
                    .appending(path: "SummaryChipImport/\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var name = filename.map { URL(fileURLWithPath: $0).lastPathComponent } ?? source.lastPathComponent
                if URL(fileURLWithPath: name).pathExtension.isEmpty, !source.pathExtension.isEmpty {
                    name += "." + source.pathExtension
                }
                let destination = directory.appending(path: name)
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            }
        }
        if let coordinationError { throw coordinationError }
        guard let copied else { throw LocalDocumentError.unavailable }
        return try copied.get()
    }

    public static func discardCopy(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appending(path: "SummaryChipImport", directoryHint: .isDirectory)
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
