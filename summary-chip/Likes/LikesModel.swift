import Foundation
import Observation
import SwiftUI
import SummaryKit

/// The Likes tab (`GET /api/v1/summaries?scope=liked`): summaries the user starred, most recently
/// starred first. Stars made on this device are applied right away; reloads pick up the rest.
/// Falls back to starred summaries saved in the offline store when the server can't be reached.
@Observable
final class LikesModel {
    let api: SummaryAPIClient
    let offline: OfflineSummaryStore
    static let pageSize = 20

    private(set) var items: [Summary] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    /// The last load failed to reach the server, so `items` come from the offline store.
    private(set) var isOffline = false
    var errorMessage: String?

    private var loadGeneration = 0

    init(api: SummaryAPIClient, offline: OfflineSummaryStore) {
        self.api = api
        self.offline = offline
        items = savedLikes()
        hasLoaded = !items.isEmpty
    }

    var entries: [SummaryFeedEntry] { items.map(SummaryFeedEntry.init(likedSummary:)) }

    private func query(cursor: String?) -> SummaryListQuery {
        SummaryListQuery(scope: .liked, cursor: cursor, limit: Self.pageSize)
    }

    /// Others' links that ran out since they were saved show as expired, as the server would send them.
    private func savedLikes() -> [Summary] {
        let now = Date.now
        return offline.summaries(matching: query(cursor: nil))
            .map { summary in
                var summary = summary
                if !summary.isOwner, let expiresAt = summary.expiresAt, expiresAt <= now { summary.isExpired = true }
                return summary
            }
            .sorted { ($0.likedAt ?? .distantPast) > ($1.likedAt ?? .distantPast) }
    }

    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let page = try await api.listSummaries(query(cursor: nil))
            guard generation == loadGeneration else { return }
            items = page.items
            nextCursor = page.nextCursor
            errorMessage = nil
            isOffline = false
            hasLoaded = true
            offline.upsert(page.items)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard generation == loadGeneration else { return }
            let saved = savedLikes()
            if !saved.isEmpty || error.isOffline {
                items = saved
                nextCursor = nil
            }
            isOffline = error.isOffline
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        do {
            let page = try await api.listSummaries(query(cursor: cursor))
            guard generation == loadGeneration else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
            offline.upsert(page.items)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A star changed: a newly starred summary goes to the top, an unstarred one leaves the list.
    func apply(_ summary: Summary) {
        items.removeAll { $0.id == summary.id }
        if summary.isLiked { items.insert(summary, at: 0) }
    }

    /// A summary changed elsewhere (detail refresh, edit): update it in place.
    func upsert(_ summary: Summary) {
        guard let index = items.firstIndex(where: { $0.id == summary.id }) else { return }
        if summary.isLiked { items[index] = summary } else { items.remove(at: index) }
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    func reset() {
        loadGeneration += 1
        items = []
        nextCursor = nil
        hasLoaded = false
        errorMessage = nil
        isOffline = false
    }
}
