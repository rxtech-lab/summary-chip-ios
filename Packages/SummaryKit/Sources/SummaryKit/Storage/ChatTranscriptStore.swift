import Foundation

/// Agent conversations persisted as one JSON file per chat (the library chat, or a chat about
/// one summary) in the App Group's `Chats` directory, so reopening a chat picks up where it
/// left off. `SharedLogoutPurger` removes the directory on sign-out.
public final class ChatTranscriptStore: Sendable {
    /// The library-wide chat on the Chat tab.
    public static let libraryKey = "library"

    public static func key(summaryID: String) -> String { "summary-\(summaryID)" }

    /// The trip agent chat on a trip's screen.
    public static func key(tripID: String) -> String { "trip-\(tripID)" }

    private let directory: URL?
    private let writer = DispatchQueue(label: "com.rxlab.summary-chip.chat-store", qos: .utility)

    public init(directory: URL? = ChatTranscriptStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SummaryIdentifiers.appGroupIdentifier)?
            .appending(path: "Chats", directoryHint: .isDirectory)
    }

    public func load<Transcript: Decodable>(_ type: Transcript.Type, key: String) -> Transcript? {
        guard let url = fileURL(key: key), let data = try? Data(contentsOf: url) else { return nil }
        return try? SummaryJSON.decoder().decode(type, from: data)
    }

    public func save<Transcript: Encodable>(_ transcript: Transcript, key: String) {
        guard let url = fileURL(key: key), let data = try? SummaryJSON.encoder().encode(transcript) else { return }
        writer.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    public func remove(key: String) {
        guard let url = fileURL(key: key) else { return }
        writer.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Blocks until queued writes and removals have landed (used by tests).
    public func flush() {
        writer.sync {}
    }

    private func fileURL(key: String) -> URL? {
        let name = key.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return directory?.appending(path: "\(name).json")
    }
}
