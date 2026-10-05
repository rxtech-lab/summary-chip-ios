import Foundation
import Testing
@testable import SummaryKit

@MainActor
struct OfflineSummaryStoreTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "OfflineSummaryStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "summaries.json")
    }

    private func summary(_ id: String, daysAgo: Double, isOwner: Bool = true, title: String = "Title", tags: [String] = []) -> Summary {
        Summary(
            id: id, slug: "slug-\(id)", shareUrl: URL(string: "https://example.com/s/\(id)")!, ogImageUrl: nil,
            sourceType: .url, sourceUrl: nil, sourceTitle: nil, siteName: nil, sourceFileUrl: nil,
            title: title, summary: "Body", highlights: [], category: "Technology", tags: tags, keywords: [],
            language: "en", theme: .fallback, imageStyle: .graphic, visibility: .public, ttlDays: nil,
            expiresAt: nil, viewCount: 0, isOwner: isOwner,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400)
        )
    }

    /// Waits for the background write to land.
    private func reopen(_ url: URL) async throws -> OfflineSummaryStore {
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: url.path()) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
        return OfflineSummaryStore(fileURL: url)
    }

    @Test func persistsAcrossLaunches() async throws {
        let url = makeURL()
        let store = OfflineSummaryStore(fileURL: url)
        store.upsert([summary("a", daysAgo: 2), summary("b", daysAgo: 1)])
        let reopened = try await reopen(url)
        #expect(reopened.summaries.map(\.id) == ["b", "a"])
        #expect(reopened.summary(slug: "slug-a")?.id == "a")
    }

    @Test func firstPageDropsSummariesDeletedElsewhere() {
        let store = OfflineSummaryStore(fileURL: nil)
        store.upsert([summary("new", daysAgo: 1), summary("deleted", daysAgo: 2), summary("kept", daysAgo: 3), summary("old", daysAgo: 10)])
        store.replaceFirstPage([summary("new", daysAgo: 1), summary("kept", daysAgo: 3)], isComplete: false)
        #expect(store.summaries.map(\.id) == ["new", "kept", "old"])

        store.replaceFirstPage([summary("new", daysAgo: 1)], isComplete: true)
        #expect(store.summaries.map(\.id) == ["new"])
    }

    @Test func filtersLocally() {
        let store = OfflineSummaryStore(fileURL: nil)
        store.upsert([
            summary("mine", daysAgo: 1, title: "Swift concurrency", tags: ["swift"]),
            summary("theirs", daysAgo: 2, isOwner: false, title: "Rust ownership"),
        ])
        #expect(store.summaries(matching: .init(scope: .viewed)).map(\.id) == ["theirs"])
        #expect(store.summaries(matching: .init(q: "CONCURRENCY")).map(\.id) == ["mine"])
        #expect(store.summaries(matching: .init(tag: "swift")).map(\.id) == ["mine"])
    }

    @Test func filtersLikesLocally() {
        var liked = summary("liked", daysAgo: 2, isOwner: false)
        liked.likedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OfflineSummaryStore(fileURL: nil)
        store.upsert([summary("plain", daysAgo: 1), liked])
        #expect(store.summaries(matching: .init(scope: .liked)).map(\.id) == ["liked"])
        #expect(store.summary(id: "liked")?.isLiked == true)
        #expect(store.summary(id: "plain")?.isLiked == false)
    }

    @Test func removeAndClear() async throws {
        let url = makeURL()
        let store = OfflineSummaryStore(fileURL: url)
        store.upsert([summary("a", daysAgo: 1), summary("b", daysAgo: 2)])
        store.remove(id: "a")
        #expect(store.summaries.map(\.id) == ["b"])
        store.clear()
        #expect(store.summaries.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(OfflineSummaryStore(fileURL: url).summaries.isEmpty)
    }
}
