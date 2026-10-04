import Foundation
import Observation
import SwiftUI
import SummaryKit

struct LibraryFilter: Hashable {
    var scope: LibraryScope = .all
    var category: String?
    var tag: String?
    var visibility: SummaryVisibility?
    var source: SummaryOrigin?

    var isActive: Bool { activeCount > 0 }
    var activeCount: Int { [scope != .all, category != nil, tag != nil, visibility != nil, source != nil].filter { $0 }.count }
}

/// The library (`GET /api/v1/summaries`): your own summaries plus others' you opened from shared
/// links, newest activity first, with filters and paging. Search lives in its own tab (`SearchModel`). Everything loaded is saved to
/// the offline store, which backs the feed until (or whenever) the network answers.
@Observable
final class LibraryModel {
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
    var filter = LibraryFilter()

    private var loadGeneration = 0
    /// Reloads made to pick up translations the server was still writing; bounded so a failing one can't loop.
    private var translationReloads = 0

    init(api: SummaryAPIClient, offline: OfflineSummaryStore) {
        self.api = api
        self.offline = offline
        // Show saved summaries immediately; `reload()` replaces them once the server answers.
        items = offline.summaries
        hasLoaded = !items.isEmpty
    }

    var entries: [SummaryFeedEntry] { items.map(SummaryFeedEntry.init(summary:)) }

    private func query(cursor: String?) -> SummaryListQuery {
        SummaryListQuery(
            scope: filter.scope,
            category: filter.category,
            tag: filter.tag,
            visibility: filter.visibility,
            source: filter.source,
            cursor: cursor,
            limit: Self.pageSize
        )
    }

    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let page = try await api.listSummaries(query(cursor: nil))
            guard generation == loadGeneration else { return }
            // Animate only when refreshing an already-shown feed, so new cards slide in
            // instead of the whole list snapping.
            withAnimation(hasLoaded ? .spring(duration: 0.4) : nil) { items = page.items }
            nextCursor = page.nextCursor
            errorMessage = nil
            isOffline = false
            hasLoaded = true
            scheduleTranslationReload(for: page.items)
            if !filter.isActive {
                RecentSummariesCache.save(page.items)
                offline.replaceFirstPage(page.items, isComplete: page.nextCursor == nil)
            } else {
                offline.upsert(page.items)
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard generation == loadGeneration else { return }
            // Fall back to what's saved on the device, filtered locally.
            let saved = offline.summaries(matching: query(cursor: nil))
            if !saved.isEmpty || error.isOffline {
                withAnimation(hasLoaded ? .spring(duration: 0.4) : nil) { items = saved }
                nextCursor = nil
            }
            isOffline = error.isOffline
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    /// Others' summaries are translated into the user's language after the list returns; check back once.
    private func scheduleTranslationReload(for items: [Summary]) {
        guard items.contains(where: \.translationPending), translationReloads < 3 else {
            translationReloads = 0
            return
        }
        translationReloads += 1
        Task {
            try? await Task.sleep(for: .seconds(5))
            await reload()
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

    func insert(_ summary: Summary) {
        items.removeAll { $0.id == summary.id }
        items.insert(summary, at: 0)
        RecentSummariesCache.save(items)
        offline.upsert(summary)
    }

    /// Saves a summary fetched elsewhere (detail refresh, deep link) and updates it in the feed.
    func upsert(_ summary: Summary) {
        offline.upsert(summary)
        if let index = items.firstIndex(where: { $0.id == summary.id }) {
            items[index] = summary
        }
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        offline.remove(id: id)
    }

    func reset() {
        loadGeneration += 1
        items = []
        nextCursor = nil
        hasLoaded = false
        filter = LibraryFilter()
        errorMessage = nil
        isOffline = false
        offline.clear()
    }
}
