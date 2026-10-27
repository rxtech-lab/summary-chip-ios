import Foundation
import Testing
@testable import SummaryKit

struct PublishedPodcastVideoTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PODCAST_DOWNLOAD_SIMULATION_URL"] != nil))
    @MainActor func downloadsPublishedTranslationWithoutLeakingTokenAndRejectsStaleOrPartialFiles() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["PODCAST_DOWNLOAD_SIMULATION_URL"])
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["x-fixture-base": base]
        let api = SummaryAPIClient(baseURL: try #require(URL(string: base)), tokenProvider: DownloadFixtureToken(),
                                   session: URLSession(configuration: config))
        let episode = try SummaryJSON.decoder().decode(DailyPodcast.self, from: Data(#"""
        {"key":"success","title":"Published","language":"ja","originalLanguage":"en",
         "day":{"start":"2030-04-01T00:00:00Z","end":"2030-04-02T00:00:00Z"},
         "createdAt":"2030-04-01T00:00:00Z","speakers":[],"segments":[],
         "video":{"id":"published-video","createdAt":"2030-04-01T00:00:00Z",
          "published":{"videoId":"published-video","byteSize":4,"publishedAt":"2030-04-01T00:00:00Z"}}}
        """#.utf8))
        var progress: [MediaTransferProgress] = []
        let file = try await api.downloadPublishedPodcastVideo(episode) { progress.append($0) }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == Data("mp4!".utf8))
        #expect(progress.last == .init(completedBytes: 4, totalBytes: 4))
        for key in ["stale", "truncated"] {
            var changed = episode
            changed.key = key
            await #expect(throws: SummaryAPIError.invalidResponse) {
                _ = try await api.downloadPublishedPodcastVideo(changed)
            }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PODCAST_DOWNLOAD_SIMULATION_URL"] != nil))
    @MainActor func downloadsCloudTranslationAndRejectsStaleFailedPartialAnd4K() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["PODCAST_DOWNLOAD_SIMULATION_URL"])
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["x-fixture-base": base]
        let api = SummaryAPIClient(baseURL: try #require(URL(string: base)), tokenProvider: DownloadFixtureToken(),
                                   session: URLSession(configuration: config))
        let episode = try SummaryJSON.decoder().decode(DailyPodcast.self, from: Data(#"""
        {"key":"cloud","title":"Cloud","language":"ja","originalLanguage":"en",
         "day":{"start":"2030-04-01T00:00:00Z","end":"2030-04-02T00:00:00Z"},
         "createdAt":"2030-04-01T00:00:00Z","speakers":[],"segments":[],
         "video":{"id":"published-video","createdAt":"2030-04-01T00:00:00Z"}}
        """#.utf8))
        var progress: [MediaTransferProgress] = []
        let file = try await api.downloadCloudPodcastVideo(episode) { progress.append($0) }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == Data("mp4!".utf8))
        #expect(progress.last == .init(completedBytes: 4, totalBytes: 4))
        for key in ["stale", "truncated"] {
            var changed = episode; changed.key = key
            await #expect(throws: SummaryAPIError.invalidResponse) { _ = try await api.downloadCloudPodcastVideo(changed) }
        }
        var failed = episode; failed.key = "failed"
        await #expect(throws: SummaryAPIError.self) { _ = try await api.downloadCloudPodcastVideo(failed) }
        await #expect(throws: SummaryAPIError.invalidResponse) { _ = try await api.downloadCloudPodcastVideo(episode, resolution: 2160) }
    }

}

private struct DownloadFixtureToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "podcast-download-fixture" }
}
