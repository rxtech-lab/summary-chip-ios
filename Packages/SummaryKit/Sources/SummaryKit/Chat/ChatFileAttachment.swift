#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import UniformTypeIdentifiers

/// A snapshot of a selected file. Its bytes can be uploaded after the picker's access ends.
public struct ChatFileAttachment: Identifiable, Sendable {
    public let id = UUID()
    public let filename: String
    public let mimeType: String
    public let data: Data

    public static let maxCount = 5
    public static let maxBytes = 25 * 1024 * 1024
    static let maxTextBytes = 200_000

    public static var contentTypes: [UTType] {
        [.pdf, .image] + LocalDocument.textContentTypes
    }

    /// Coordinates with iCloud Drive and other Files providers. Call off the main thread.
    public static func read(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw ImportError.unsupported }
        return try LocalDocument.withCoordinatedRead(url) { source in
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
            guard values.isRegularFile == true else { throw ImportError.unsupported }
            guard let size = values.fileSize, size > 0 else { throw LocalDocumentError.empty }
            guard size <= maxBytes else { throw ImportError.fileTooLarge }

            let filename = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let type = values.contentType ?? UTType(filenameExtension: ext) ?? .data
            if type.conforms(to: .pdf) {
                guard CGPDFDocument(source as CFURL) != nil else { throw ImportError.unreadablePDF }
                return Self(filename: filename, mimeType: "application/pdf", data: try Data(contentsOf: source))
            }
            if type.conforms(to: .image) {
                return try image(source, filename: filename)
            }
            guard type.conforms(to: .text) || LocalDocument.markdownExtensions.contains(ext)
                    || LocalDocument.codeExtensions.contains(ext) else { throw ImportError.unsupported }
            let text: String
            if type.conforms(to: .rtf) {
                text = try NSAttributedString(url: source, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            } else {
                text = try LocalDocument.decodeText(at: source, trusted: true)
            }
            guard !text.isEmpty else { throw LocalDocumentError.empty }
            guard text.utf8.count <= maxTextBytes else { throw ImportError.textTooLarge }
            let data = Data(text.utf8)
            guard LocalDocument.looksLikeText(data) else { throw ImportError.unsupported }
            return Self(filename: filename, mimeType: "text/plain", data: data)
        }
    }

    private static func image(_ url: URL, filename: String) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else { throw ImportError.unreadableImage }
        if let mime = type.preferredMIMEType, ["image/jpeg", "image/png", "image/webp"].contains(mime) {
            return Self(filename: filename, mimeType: mime, data: try Data(contentsOf: url))
        }
        // Providers accept these other formats as still images. Apply the embedded orientation
        // and bound decoded memory when opening large HEIC, TIFF or camera images.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.unreadableImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.unreadableImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadableImage }
        guard output.length <= maxBytes else { throw ImportError.fileTooLarge }
        return Self(filename: filename, mimeType: "image/jpeg", data: output as Data)
    }

    private enum ImportError: LocalizedError {
        case unsupported, unreadableImage, unreadablePDF, fileTooLarge, textTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "Choose a text file, PDF or image.", bundle: .module)
            case .unreadableImage: String(localized: "This image could not be read.", bundle: .module)
            case .unreadablePDF: String(localized: "This PDF could not be read.", bundle: .module)
            case .fileTooLarge: String(localized: "Chat attachments can be up to 25 MiB each.", bundle: .module)
            case .textTooLarge: String(localized: "Text attachments can contain up to 200 KB of UTF-8 text.", bundle: .module)
            }
        }
    }
}
