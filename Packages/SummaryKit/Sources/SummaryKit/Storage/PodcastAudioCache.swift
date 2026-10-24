import CryptoKit
import Foundation

/// Complete episode recordings, retained for seven days from download (reads do not extend TTL).
/// Cache failures never prevent playback. The OS can also reclaim this cache under disk pressure.
public final class PodcastAudioCache: @unchecked Sendable {
    public static let shared = PodcastAudioCache()
    public static let timeToLive: TimeInterval = 7 * 24 * 60 * 60

    private let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var generation = UUID()

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "PodcastAudio", directoryHint: .isDirectory),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    func data(for key: String, download: @Sendable () async throws -> Data) async throws -> Data {
        let (cached, generation) = lookup(key)
        if let cached { return cached }
        let data = try await download()
        try Task.checkCancellation()
        store(data, for: key, generation: generation)
        return data
    }

    public func clear() {
        lock.withLock {
            // Downloads already in flight must not repopulate a cleared cache, including on logout.
            generation = UUID()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func remove(_ key: String) {
        lock.withLock {
            generation = UUID()
            try? FileManager.default.removeItem(at: fileURL(for: key))
        }
    }

    public var diskSize: Int {
        lock.withLock {
            pruneExpired()
            return files().reduce(0) { total, url in
                total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }

    private func lookup(_ key: String) -> (Data?, UUID) {
        lock.withLock {
            pruneExpired()
            let url = fileURL(for: key)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return (nil, generation)
            }
            return (data, generation)
        }
    }

    private func store(_ data: Data, for key: String, generation: UUID) {
        lock.withLock {
            guard self.generation == generation, !data.isEmpty else { return }
            let fileManager = FileManager.default
            let url = fileURL(for: key)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            } catch {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func fileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: hash).appendingPathExtension("audio")
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
    }

    private func pruneExpired() {
        let cutoff = now().addingTimeInterval(-Self.timeToLive)
        for url in files() {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified == nil || modified! <= cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
