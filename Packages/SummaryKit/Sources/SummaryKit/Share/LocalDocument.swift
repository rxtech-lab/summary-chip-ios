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
        case .unsupported: "Choose a PDF, plain text or Markdown file."
        case .empty: "This file is empty."
        case .noPDFText: "This PDF has no selectable text. Scanned PDFs can't be read on this device."
        case .textTooLong: "Text files must contain at most 200,000 characters."
        case .unavailable: "The local file is unavailable. Choose it again in Files to restore access."
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
}

/// Coordinates reads from Files providers, including iCloud downloads, while access is held.
public enum LocalDocument {
    public static var contentTypes: [UTType] {
        [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]
    }

    /// The server's JavaScript limit counts UTF-16 code units.
    public static let maxTextLength = 200_000

    public static func input(fileURL: URL, filename: String? = nil) throws -> SummaryInput {
        .localFile(try read(fileURL: fileURL, filename: filename))
    }

    /// Reads a file that is already accessible (a staged copy, or inside a security scope).
    public static func read(fileURL: URL, filename: String? = nil) throws -> LocalFileSource {
        let name = filename ?? fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        guard ext == "pdf" || ext == "md" || ext == "markdown" || type?.conforms(to: .plainText) == true else {
            throw LocalDocumentError.unsupported
        }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
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
        var encoding = String.Encoding.utf8
        let text = try String(contentsOf: fileURL, usedEncoding: &encoding).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalDocumentError.empty }
        guard text.utf16.count <= maxTextLength else { throw LocalDocumentError.textTooLong }
        return LocalFileSource(filename: name, kind: .text, text: text)
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
