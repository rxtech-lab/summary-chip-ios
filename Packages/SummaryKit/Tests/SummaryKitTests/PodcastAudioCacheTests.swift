import Foundation
import Testing
@testable import SummaryKit

struct PodcastAudioCacheTests {
    private let audio = Data("recording".utf8)

    @Test func persistsAcrossInstancesWithoutExtendingSevenDayTTL() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let first = PodcastAudioCache(directory: folder, now: { start })
        #expect(try await first.data(for: "episode") { audio } == audio)
        let beforeExpiry = PodcastAudioCache(directory: folder, now: { start.addingTimeInterval(PodcastAudioCache.timeToLive - 1) })
        #expect(try await beforeExpiry.data(for: "episode") { throw CacheTestError.unexpectedDownload } == audio)
        let expired = PodcastAudioCache(directory: folder, now: { start.addingTimeInterval(PodcastAudioCache.timeToLive) })
        #expect(expired.diskSize == 0)
        #expect(try await expired.data(for: "episode") { Data("new".utf8) } == Data("new".utf8))
    }

    @Test func separatesVersionsAndHostsAndEvictsRemovedRecordings() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = PodcastAudioCache(directory: folder)
        for key in ["https://one.test/v1/audio", "https://one.test/v2/audio", "https://two.test/v1/audio"] {
            #expect(try await cache.data(for: key) { Data(key.utf8) } == Data(key.utf8))
        }
        #expect(try await cache.data(for: "https://one.test/v1/audio") { throw CacheTestError.unexpectedDownload }
                == Data("https://one.test/v1/audio".utf8))
        cache.remove("https://one.test/v1/audio")
        #expect(try await cache.data(for: "https://one.test/v1/audio") { audio } == audio)
        cache.clear()
        #expect(cache.diskSize == 0)
    }

    @Test func failedAndCancelledDownloadsAreNotStored() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = PodcastAudioCache(directory: folder)
        await #expect(throws: CacheTestError.self) {
            _ = try await cache.data(for: "failure") { throw CacheTestError.unexpectedDownload }
        }
        let task = Task {
            try await cache.data(for: "cancelled") {
                withUnsafeCurrentTask { $0?.cancel() }
                return audio
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(cache.diskSize == 0)
    }

    @Test func clearDuringDownloadPreventsRepopulation() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = PodcastAudioCache(directory: folder)
        #expect(try await cache.data(for: "episode") {
            cache.clear()
            return audio
        } == audio)
        #expect(cache.diskSize == 0)
    }

    @Test func unwritableCacheDoesNotBlockPlayback() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("file instead of directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = PodcastAudioCache(directory: file)
        #expect(try await cache.data(for: "episode") { audio } == audio)
    }
}

private enum CacheTestError: Error { case unexpectedDownload }
