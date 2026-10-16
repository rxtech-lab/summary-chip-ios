import ImageIO
import PhotosUI
import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// A `FilePicker`: lets the user pick a photo or a local file, uploads it to the saved Clip and
/// writes the file reference `{id, url, name, contentType, size, …}` (an array with `multiple`) to
/// `binding`, then fires `change`. `accept: "file"` opens Files directly; `image` and `any` offer
/// the photo library and Files. In an unsaved preview the file stays on the device.
struct MiniFilePicker: View {
    @Bindable var model: MiniAppRuntime
    let node: MiniAppNode
    let item: JSONValue
    let title: String
    let icon: String
    @State private var photos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var uploaded = 0

    private var accept: String { node.props["accept"]?.stringValue ?? "any" }
    private var multiple: Bool { node.props["multiple"]?.miniTruth == true }

    var body: some View {
        Group {
            if accept == "file" {
                Button { showsFiles = true } label: { Label(title, systemImage: icon) }
            } else {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotos = true }
                    Button("Choose File…", systemImage: "folder") { showsFiles = true }
                } label: { Label(title, systemImage: icon) }
            }
        }
        .disabled(model.uploading > 0)
        .photosPicker(isPresented: $showsPhotos, selection: $photos, maxSelectionCount: multiple ? 10 : 1, matching: .images)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: accept == "image" ? [.image] : [.item], allowsMultipleSelection: multiple) { result in
            guard let urls = try? result.get(), !urls.isEmpty else { return }
            Task { await upload(urls.prefix(10).map(MiniPickedFile.Source.file)) }
        }
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task { await upload(picked.map(MiniPickedFile.Source.photo)) }
        }
        .sensoryFeedback(.selection, trigger: showsPhotos || showsFiles) { _, new in new }
        .sensoryFeedback(.success, trigger: uploaded)
    }

    private func upload(_ sources: [MiniPickedFile.Source]) async {
        model.uploading += 1
        defer { model.uploading -= 1 }
        do {
            var references: [JSONValue] = []
            for source in sources {
                let file = try await MiniPickedFile.load(source)
                if let app = model.app {
                    references.append(try await model.api.uploadMiniAppFile(id: app.id, data: file.data, filename: file.filename, mimeType: file.mimeType))
                } else {
                    references.append(try file.previewReference())
                }
            }
            guard let first = references.first else { return }
            model.binding(node.props["binding"]?.stringValue ?? "file").wrappedValue = multiple ? .array(references) : first
            uploaded += 1
            model.event(node, "change", item: item)
        } catch {
            model.error = error.localizedDescription
        }
    }
}

/// A picked photo or file, read off the main thread. Photos and image formats other servers can't
/// decode (HEIC, TIFF, RAW…) become JPEGs on the device; the server strips metadata when it stores them.
nonisolated struct MiniPickedFile: Sendable {
    enum Source {
        case photo(PhotosPickerItem)
        case file(URL)
    }

    let data: Data
    let filename: String
    let mimeType: String

    private static let passthroughImages: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    static func load(_ source: Source) async throws -> MiniPickedFile {
        switch source {
        case .photo(let item):
            guard let data = try await item.loadTransferable(type: Data.self) else { throw MiniFileError.unreadable }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            return try await Task.detached { try image(data, type: type, filename: String(localized: "Photo")) }.value
        case .file(let url):
            return try await Task.detached { try read(url) }.value
        }
    }

    private static func read(_ url: URL) throws -> MiniPickedFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= SummaryAPIClient.maxUploadBytes else { throw SummaryAPIError.fileTooLarge(maxBytes: SummaryAPIClient.maxUploadBytes) }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) { return try image(data, type: type, filename: url.deletingPathExtension().lastPathComponent) }
        return MiniPickedFile(data: data, filename: url.lastPathComponent, mimeType: type.preferredMIMEType ?? "application/octet-stream")
    }

    private static func image(_ data: Data, type: UTType, filename: String) throws -> MiniPickedFile {
        if let mime = type.preferredMIMEType, passthroughImages.contains(mime), let ext = type.preferredFilenameExtension {
            return MiniPickedFile(data: data, filename: "\(filename).\(ext)", mimeType: mime)
        }
        // Upright and at most 4096 px: the server resizes to 2048 px anyway.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { throw MiniFileError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw MiniFileError.unreadable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MiniFileError.unreadable }
        return MiniPickedFile(data: output as Data, filename: "\(filename).jpg", mimeType: "image/jpeg")
    }

    /// The preview has no saved Clip to upload to: keep a temporary copy and point at it.
    func previewReference() throws -> JSONValue {
        let id = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appending(path: "clip-files/\(id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: filename)
        try data.write(to: url)
        return .object([
            "id": .string(id), "url": .string(url.absoluteString), "name": .string(filename),
            "contentType": .string(mimeType), "size": .number(Double(data.count))
        ])
    }
}

private enum MiniFileError: LocalizedError {
    case unreadable
    var errorDescription: String? { String(localized: "The file couldn't be read.") }
}
