import Foundation
import UniformTypeIdentifiers

public enum SharePayloadError: LocalizedError, Equatable {
    case noSupportedItems
    case cannotRead(String)

    public var errorDescription: String? {
        switch self {
        case .noSupportedItems: String(localized: "Chippy can summarise web pages, links, PDFs and text. Nothing like that was shared.", bundle: .module)
        case .cannotRead(let name): String(localized: "Chippy couldn't read \(name).", bundle: .module)
        }
    }
}

/// Everything the loader could pull out of the share, before deciding what to summarise.
public struct RawShareContents: Sendable, Equatable {
    /// Result of ExtractContent.js (`NSExtensionJavaScriptPreprocessingResultsKey`).
    public var preprocessing: [String: String]?
    public var pdfFile: URL?
    public var pdfFilename: String?
    public var url: URL?
    public var text: String?
    /// A staged copy of a shared local file, kept on the device with the summary.
    public var localFile: URL?
    public var localFilename: String?
    /// What was read from `localFile` on the device.
    public var localDocument: LocalFileSource?

    public init(preprocessing: [String: String]? = nil, pdfFile: URL? = nil, pdfFilename: String? = nil, url: URL? = nil, text: String? = nil, localFile: URL? = nil, localFilename: String? = nil, localDocument: LocalFileSource? = nil) {
        self.preprocessing = preprocessing
        self.pdfFile = pdfFile
        self.pdfFilename = pdfFilename
        self.url = url
        self.text = text
        self.localFile = localFile
        self.localFilename = localFilename
        self.localDocument = localDocument
    }
}

/// Pure decision logic: which `SummaryInput` a share turns into.
///
/// Order: JS preprocessing (→ `webpage`) → PDF (→ upload + `pdf`, keeping the page URL)
/// → URL (→ `url`) → text (→ `text`, or `url` when the text is only a link).
public enum ShareClassifier {
    public static let minimumWebpageContent = 200

    public static func classify(_ raw: RawShareContents) -> SummaryInput? {
        let webURL = raw.url.flatMap(webOnly)

        if let results = raw.preprocessing,
           let urlString = results["url"], let pageURL = URL(string: urlString).flatMap(webOnly) {
            let content = (results["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A PDF opened in Safari runs the script against the PDF viewer: prefer the file.
            if raw.pdfFile == nil, raw.localFile == nil {
                if content.count >= minimumWebpageContent {
                    return .webpage(WebpageSource(
                        url: pageURL,
                        title: nonEmpty(results["title"]),
                        content: content,
                        html: nonEmpty(results["html"]),
                        siteName: nonEmpty(results["siteName"]),
                        lang: nonEmpty(results["lang"])
                    ))
                }
                // Too little text extracted (SPA, paywall): let the server fetch the page.
                return .url(pageURL)
            }
        }

        if let pdf = raw.pdfFile {
            let preprocessedURL = raw.preprocessing?["url"].flatMap(URL.init(string:)).flatMap(webOnly)
            let sourceURL = webURL ?? preprocessedURL
            let filename = nonEmpty(raw.pdfFilename) ?? pdf.lastPathComponent
            return .pdf(fileURL: pdf, filename: filename.lowercased().hasSuffix(".pdf") ? filename : filename + ".pdf", sourceURL: sourceURL)
        }

        if raw.localFile != nil, let document = raw.localDocument {
            return .localFile(document)
        }

        if let webURL { return .url(webURL) }

        if let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let link = singleURL(in: text) { return .url(link) }
            return .text(text, title: nil)
        }
        return nil
    }

    /// What the user typed or dictated: a lone web link is read by the server, anything else is
    /// summarised as text. Blank input is `nil`.
    public static func classify(typed text: String) -> SummaryInput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = singleURL(in: trimmed) { return .url(url) }
        return .text(trimmed, title: nil)
    }

    /// Returns the URL when `text` is nothing but one http(s) link.
    public static func singleURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return nil }
        return webOnly(url)
    }

    static func webOnly(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Reads `NSExtensionItem`s handed to the share extension.
public enum SharePayloadLoader {
    public static let preprocessingResultsKey = "NSExtensionJavaScriptPreprocessingResultsKey"

    public static func load(inputItems: [Any]) async throws -> SummaryInput {
        let raw = try await loadRaw(inputItems: inputItems)
        guard let input = ShareClassifier.classify(raw) else { throw SharePayloadError.noSupportedItems }
        return input
    }

    public static func loadRaw(inputItems: [Any]) async throws -> RawShareContents {
        let providers = inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        var raw = RawShareContents()
        var completed = false
        defer {
            if !completed {
                if let file = raw.pdfFile { LocalDocument.discardCopy(file) }
                if let file = raw.localFile { LocalDocument.discardCopy(file) }
            }
        }

        for provider in providers {
            if raw.preprocessing == nil, provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
                raw.preprocessing = await loadPreprocessing(from: provider)
            }
            if raw.pdfFile == nil, provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                raw.pdfFile = try await copyFile(from: provider, typeIdentifier: UTType.pdf.identifier)
                raw.pdfFilename = provider.suggestedName ?? raw.pdfFile?.lastPathComponent
            }
            if raw.pdfFile == nil, raw.localFile == nil {
                let textType = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .plainText) == true || $0 == UTType(filenameExtension: "md")?.identifier
                }
                let suggestedExtension = provider.suggestedName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
                if let textType, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || textType != UTType.plainText.identifier || ["txt", "md", "markdown"].contains(suggestedExtension ?? "") {
                    let file = try await copyFile(from: provider, typeIdentifier: textType)
                    raw.localFile = file
                    raw.localFilename = provider.suggestedName ?? file.lastPathComponent
                    raw.localDocument = try LocalDocument.read(fileURL: file, filename: raw.localFilename)
                } else if let suggestedExtension, LocalDocument.isReadable(extension: suggestedExtension),
                          let documentType = provider.registeredTypeIdentifiers.first(where: { LocalDocument.isReadable(typeIdentifier: $0) }) {
                    // A named attachment (Mail, Messages…) such as an RTF, Word or code file.
                    let file = try await copyFile(from: provider, typeIdentifier: documentType)
                    raw.localFile = file
                    raw.localFilename = provider.suggestedName ?? file.lastPathComponent
                    raw.localDocument = try LocalDocument.read(fileURL: file, filename: raw.localFilename)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                          let url = await loadURL(from: provider, typeIdentifier: UTType.fileURL.identifier), url.isFileURL {
                    let file = try LocalDocument.copyForReading(url)
                    do {
                        raw.localDocument = try LocalDocument.read(fileURL: file, filename: url.lastPathComponent)
                        raw.localFile = file
                        raw.localFilename = url.lastPathComponent
                    } catch {
                        LocalDocument.discardCopy(file)
                        throw error
                    }
                }
            }
            if raw.url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                raw.url = await loadURL(from: provider)
            }
            if raw.text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                raw.text = await loadText(from: provider)
            }
        }
        if let file = raw.pdfFile {
            if let textFile = raw.localFile {
                LocalDocument.discardCopy(textFile)
                raw.localFile = nil
                raw.localFilename = nil
                raw.localDocument = nil
            }
            let preprocessedURL = raw.preprocessing?["url"].flatMap(URL.init(string:)).flatMap(ShareClassifier.webOnly)
            if raw.url.flatMap(ShareClassifier.webOnly) == nil, preprocessedURL == nil {
                // Not from the web (Files, Mail…): read it here instead of uploading it.
                raw.localDocument = try LocalDocument.read(fileURL: file, filename: raw.pdfFilename)
                raw.localFile = file
                raw.localFilename = raw.pdfFilename
                raw.pdfFile = nil
                raw.pdfFilename = nil
            } else {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= SummaryAPIClient.maxUploadBytes else {
                    throw SummaryAPIError.fileTooLarge(maxBytes: SummaryAPIClient.maxUploadBytes)
                }
            }
        }
        completed = true
        return raw
    }

    private static func loadPreprocessing(from provider: NSItemProvider) async -> [String: String]? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { value, _ in
                var result: [String: String]?
                if let dictionary = value as? NSDictionary,
                   let results = dictionary[preprocessingResultsKey] as? NSDictionary {
                    var strings: [String: String] = [:]
                    for (key, value) in results {
                        if let key = key as? String, let value = value as? String { strings[key] = value }
                    }
                    result = strings
                }
                continuation.resume(returning: result)
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider, typeIdentifier: String = UTType.url.identifier) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { value, _ in
                var url: URL?
                if let value = value as? URL { url = value }
                else if let value = value as? NSURL { url = value as URL }
                else if let value = value as? String { url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) }
                else if let data = value as? Data, let string = String(data: data, encoding: .utf8) {
                    url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { value, _ in
                var text: String?
                if let value = value as? String { text = value }
                else if let value = value as? NSAttributedString { text = value.string }
                else if let data = value as? Data { text = String(data: data, encoding: .utf8) }
                else if let url = value as? URL, url.isFileURL { text = try? String(contentsOf: url, encoding: .utf8) }
                continuation.resume(returning: text)
            }
        }
    }

    private static func copyFile(from provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        let suggestedName = provider.suggestedName ?? "file"
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { source, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let source else {
                    continuation.resume(throwing: SharePayloadError.cannotRead(suggestedName))
                    return
                }
                do {
                    // The provider removes its file when this callback returns.
                    let destination = try LocalDocument.copyForReading(source)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
