import Foundation
import Observation
import SwiftUI
import SummaryKit

/// Backs the dedicated Search tab: server-side `q` search over the whole library, kept apart from
/// the Library feed so searching never disturbs it. Falls back to the offline store when the
/// server can't be reached.
@Observable
final class SearchModel {
    private let api: SummaryAPIClient
    private let offline: OfflineSummaryStore
    static let pageSize = 20

    private(set) var items: [Summary] = []
    private(set) var nextCursor: String?
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    /// The query the current `items` answer; empty until a search completes.
    private(set) var loadedQuery = ""
    private(set) var isOffline = false
    var errorMessage: String?
    var searchText = ""

    private var generation = 0

    init(api: SummaryAPIClient, offline: OfflineSummaryStore) {
        self.api = api
        self.offline = offline
    }

    var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var entries: [SummaryFeedEntry] { items.map(SummaryFeedEntry.init(summary:)) }

    private func listQuery(_ q: String, cursor: String?) -> SummaryListQuery {
        SummaryListQuery(q: q, cursor: cursor, limit: Self.pageSize)
    }

    /// Debounces, then runs the search for the current text. Call from `.task(id: searchText)`.
    func search() async {
        let q = query
        generation += 1
        let current = generation
        guard !q.isEmpty else {
            items = []
            nextCursor = nil
            loadedQuery = ""
            isSearching = false
            errorMessage = nil
            return
        }
        guard q != loadedQuery else { return }
        isSearching = true
        defer { if current == generation { isSearching = false } }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, current == generation else { return }
        do {
            let page = try await api.listSummaries(listQuery(q, cursor: nil))
            guard current == generation else { return }
            withAnimation(.spring(duration: 0.3)) { items = page.items }
            nextCursor = page.nextCursor
            loadedQuery = q
            isOffline = false
            errorMessage = nil
            offline.upsert(page.items)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard current == generation else { return }
            items = offline.summaries(matching: listQuery(q, cursor: nil))
            nextCursor = nil
            loadedQuery = q
            isOffline = error.isOffline
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, !isSearching else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let current = generation
        do {
            let page = try await api.listSummaries(listQuery(loadedQuery, cursor: cursor))
            guard current == generation else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
            offline.upsert(page.items)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
    }
}
