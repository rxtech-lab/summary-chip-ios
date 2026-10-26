import Foundation
import Observation
import SwiftUI
import SummaryKit
import WidgetKit

struct LibraryFilter: Hashable {
    var scope: LibraryScope = .all
    var category: String?
    var tag: String?
    var visibility: SummaryVisibility?
    var source: SummaryOrigin?
    /// Restricts the library to one document kind.
    var kind: SummaryKind?
    var editorsPick = false

    var isActive: Bool { activeCount > 0 }
    var activeCount: Int { [scope != .all, category != nil, tag != nil, visibility != nil, source != nil, kind != nil, editorsPick].filter { $0 }.count }
}

/// The library (`GET /api/v1/summaries`): your own summaries plus others' you opened from shared
/// links, newest activity first, with filters and paging. Search lives in its own tab (`SearchModel`). Everything loaded is saved to
/// the offline store, which backs the feed until (or whenever) the network answers.
@Observable
final class LibraryModel {
    let api: SummaryAPIClient
    let offline: OfflineSummaryStore
    /// A dedicated document tab keeps its kind separate from user-selected filters.
    let kind: SummaryKind?
    var excludedKind: SummaryKind? { kind == nil ? .miniApp : nil }
    var availableKinds: [SummaryKind] { SummaryKind.known.filter { $0 != excludedKind } }
    static let pageSize = 20

    private(set) var items: [Summary] = []
    private(set) var editorPickIDs: Set<String> = []
    @ObservationIgnored private var headlineTask: Task<Void, Never>?
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

    init(api: SummaryAPIClient, offline: OfflineSummaryStore, kind: SummaryKind? = nil) {
        self.api = api
        self.offline = offline
        self.kind = kind
        // Show saved summaries immediately; `reload()` replaces them once the server answers.
        items = offline.summaries(matching: SummaryListQuery(kind: kind, excludeKind: kind == nil ? .miniApp : nil))
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
            kind: kind ?? filter.kind,
            excludeKind: excludedKind,
            editorsPick: filter.editorsPick,
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
            items = page.items
            nextCursor = page.nextCursor
            errorMessage = nil
            isOffline = false
            hasLoaded = true
            scheduleTranslationReload(for: page.items)
            refreshHeadlines()
            if kind == nil && !filter.isActive {
                RecentSummariesCache.save(page.items)
                offline.replaceFirstPage(page.items, isComplete: page.nextCursor == nil, excludingKind: excludedKind)
            } else {
                offline.upsert(page.items)
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard generation == loadGeneration else { return }
            // Fall back to what's saved on the device, filtered locally.
            let saved = offline.summaries(matching: query(cursor: nil), editorPickIDs: editorPickIDs)
            if !saved.isEmpty || error.isOffline || filter.editorsPick {
                items = saved
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
        offline.upsert(summary)
        if summary.kind == .summary || summary.kind == .podcast { refreshHeadlines() }
        guard summary.kind != excludedKind, kind == nil || summary.kind == kind else { return }
        guard !filter.editorsPick || editorPickIDs.contains(summary.id) else { return }
        items.removeAll { $0.id == summary.id }
        items.insert(summary, at: 0)
        if kind == nil && !filter.isActive { RecentSummariesCache.save(items) }
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
        editorPickIDs.remove(id)
        refreshHeadlines()
    }

    private func refreshHeadlines() {
        guard kind == nil || kind == .summary || kind == .podcast else { return }
        headlineTask?.cancel()
        headlineTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<5 {
                do {
                    let result = try await api.headlines()
                    try Task.checkCancellation()
                    editorPickIDs = Set(result.editorPickIDs ?? result.highlighted.map { [$0.id] } ?? [])
                    if !result.pending {
                        WidgetCenter.shared.reloadTimelines(ofKind: "ChippyHeadline")
                        return
                    }
                    if attempt < 4 { try await Task.sleep(for: .seconds(10)) }
                } catch { return }
            }
        }
    }

    func reset() {
        headlineTask?.cancel()
        headlineTask = nil
        editorPickIDs = []
        WidgetCenter.shared.reloadTimelines(ofKind: "ChippyHeadline")
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
