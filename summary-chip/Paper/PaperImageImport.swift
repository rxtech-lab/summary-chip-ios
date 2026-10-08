import Foundation
import ImageIO
import SummaryKit
import UniformTypeIdentifiers

/// Image bytes stay local until the user saves the figure sheet.
nonisolated struct PaperImageImport: Identifiable, Hashable, Sendable {
    let id = UUID()
    let data: Data
    let filename: String
    let fileExtension: String

    static let dropTypes: [UTType] = [.image, .pdf, .fileURL]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(data: Data, filename: String, fileExtension: String) throws {
        try PaperLimits.validateImage(path: "image.\(fileExtension)", data: data)
        self.data = data
        self.filename = filename
        self.fileExtension = fileExtension
    }

    static func read(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw PaperProjectError(String(localized: "Choose a local image file.")) }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= PaperLimits.maxImageBytes else { throw tooLarge }
        return try Self(data: Data(contentsOf: url), filename: url.lastPathComponent, fileExtension: url.pathExtension.lowercased())
    }

    func stagedFile(in source: PaperSource, replacing: PaperFile? = nil) throws -> PaperFile {
        let stem = (filename as NSString).deletingPathExtension.map { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "-" || char == "_") ? String(char) : "-"
        }.joined().prefix(80)
        let name = stem.isEmpty ? "image" : String(stem)
        var path = replacing?.path ?? "images/\(name).\(fileExtension)"
        var number = 2
        while replacing == nil, source.file(path) != nil {
            path = "images/\(name)-\(number).\(fileExtension)"
            number += 1
        }
        try PaperLimits.validateImage(path: path, data: data)
        let mime = fileExtension == "png" ? "image/png" : fileExtension == "pdf" ? "application/pdf" : "image/jpeg"
        let file = PaperFile(path: path, asset: PaperAsset(key: "pending", mimeType: mime, byteSize: data.count))
        var project = source
        project.write(file)
        if let problem = PaperLimits.problem(with: project) { throw PaperProjectError(problem) }
        return file
    }

    /// Start loading in the drop callback: the provider's access is scoped to that operation.
    static func load(_ provider: NSItemProvider, completion: @escaping @Sendable (Result<Self, Error>) -> Void) {
        if let type = [UTType.png, .jpeg, .pdf].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            loadData(provider, type: type, completion: completion)
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                completion(Result {
                    if let error { throw error }
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let value = item as? Data, let string = String(data: value, encoding: .utf8) {
                        url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    else if let value = item as? String { url = URL(string: value) }
                    else { url = nil }
                    guard let url else { throw unreadable }
                    return try read(url)
                })
            }
            return
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { completion(.failure(unreadable)); return }
        loadData(provider, type: .image, completion: completion)
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType, completion: @escaping @Sendable (Result<Self, Error>) -> Void) {
        let name = provider.suggestedName ?? "image"
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            completion(Result {
                if let error { throw error }
                guard let data else { throw unreadable }
                return try decode(data, filename: name)
            })
        }
    }

    /// Photos and browsers can supply an image without a file name or in a format TeX can't use.
    static func decode(_ data: Data, filename: String) throws -> Self {
        guard data.count <= PaperLimits.maxImageBytes else { throw tooLarge }
        for ext in ["png", "jpg", "pdf"] {
            if (try? PaperLimits.validateImage(path: "image.\(ext)", data: data)) != nil {
                return try Self(data: data, filename: filename, fileExtension: ext)
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw unreadable }
        return try Self(data: output as Data, filename: filename, fileExtension: "png")
    }

    private static var tooLarge: PaperProjectError { PaperProjectError(String(localized: "Each image is limited to 10 MB.")) }
    private static var unreadable: PaperProjectError { PaperProjectError(String(localized: "Couldn't read this image. Choose a PNG, JPEG or PDF.")) }
}
