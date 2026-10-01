import Foundation

public struct LocalFileLink: Codable, Sendable, Equatable {
    public let filename: String
    public let bookmark: Data?
    public let savedFilename: String?
    public var isSavedCopy: Bool { savedFilename != nil }
}

/// Device-local associations. Never sent in the summary API or public share link.
public struct LocalFileStore: Sendable {
    private let directory: URL?

    public init(directory: URL? = LocalFileStore.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SummaryIdentifiers.appGroupIdentifier)?
            .appending(path: "LocalFiles", directoryHint: .isDirectory)
    }

    public func link(summaryID: String) -> LocalFileLink? {
        guard let url = try? folder(summaryID).appending(path: "link.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalFileLink.self, from: data)
    }

    public static func bookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public func saveBookmark(_ bookmark: Data, filename: String, summaryID: String) throws {
        try save(LocalFileLink(filename: filename, bookmark: bookmark, savedFilename: nil), summaryID: summaryID)
    }

    /// A share provider lends a temporary file, so preserve a copy in the App Group instead.
    public func saveCopy(of url: URL, filename: String, summaryID: String) throws {
        let folder = try folder(summaryID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = URL(fileURLWithPath: filename).lastPathComponent
        if URL(fileURLWithPath: name).pathExtension.isEmpty, !url.pathExtension.isEmpty {
            name += "." + url.pathExtension
        }
        let savedName = "\(UUID().uuidString)-\(name)"
        let destination = folder.appending(path: savedName)
        let staged = try LocalDocument.copyForReading(url)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: staged, to: destination)
        do {
            try save(LocalFileLink(filename: filename, bookmark: nil, savedFilename: savedName), summaryID: summaryID)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func resolve(summaryID: String) throws -> URL {
        guard let link = link(summaryID: summaryID) else { throw LocalDocumentError.unavailable }
        if let filename = link.savedFilename {
            let url = try folder(summaryID).appending(path: filename)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LocalDocumentError.unavailable }
            return url
        }
        guard let bookmark = link.bookmark else { throw LocalDocumentError.unavailable }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = .withoutUI
        #endif
        let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { try saveBookmark(Self.bookmark(for: url), filename: link.filename, summaryID: summaryID) }
        return url
    }

    /// Only removes the association and any copy we own; never deletes a user's original.
    public func remove(summaryID: String) throws {
        let folder = try folder(summaryID)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func save(_ link: LocalFileLink, summaryID: String) throws {
        let previous = self.link(summaryID: summaryID)
        let folder = try folder(summaryID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(link).write(to: folder.appending(path: "link.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let old = previous?.savedFilename, old != link.savedFilename {
            try? FileManager.default.removeItem(at: folder.appending(path: old))
        }
    }

    private func folder(_ summaryID: String) throws -> URL {
        guard let directory else { throw LocalDocumentError.unavailable }
        let key = Data(summaryID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        guard !key.isEmpty else { throw LocalDocumentError.unavailable }
        return directory.appending(path: key, directoryHint: .isDirectory)
    }
}
