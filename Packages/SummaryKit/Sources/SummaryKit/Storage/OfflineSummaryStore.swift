import Foundation

/// Every summary the app has seen (library pages, opened details, deep links), persisted as JSON
/// in the App Group's `Cache` directory so the library and detail screens work offline.
/// `SharedLogoutPurger` removes the file on sign-out; call `clear()` to drop the in-memory copy.
@MainActor
public final class OfflineSummaryStore {
    /// Oldest entries beyond this are dropped.
    public static let capacity = 500

    /// Newest activity first, like the library.
    public private(set) var summaries: [Summary]
    private let fileURL: URL?
    private let writer = DispatchQueue(label: "com.rxlab.summary-chip.offline-store", qos: .utility)

    public init(fileURL: URL? = OfflineSummaryStore.defaultFileURL) {
        self.fileURL = fileURL
        summaries = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? SummaryJSON.decoder().decode([Summary].self, from: $0) } ?? []
    }

    public static var defaultFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SummaryIdentifiers.appGroupIdentifier)?
            .appending(path: "Cache", directoryHint: .isDirectory)
            .appending(path: "summaries.json")
    }

    public func summary(id: String) -> Summary? {
        summaries.first { $0.id == id }
    }

    public func summary(slug: String) -> Summary? {
        summaries.first { $0.slug == slug }
    }

    /// Saved summaries matching a library query, filtered on-device (used when offline).
    public func summaries(matching query: SummaryListQuery) -> [Summary] {
        let terms = (query.q ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return summaries.filter { summary in
            switch query.scope {
            case .all: break
            case .mine: guard summary.isOwner else { return false }
            case .viewed: guard !summary.isOwner else { return false }
            }
            if let category = query.category, summary.category != category { return false }
            if let tag = query.tag, !summary.tags.contains(tag) { return false }
            if let visibility = query.visibility, summary.visibility != visibility { return false }
            guard !terms.isEmpty else { return true }
            let haystack = ([summary.title, summary.summary, summary.sourceLabel] + summary.highlights + summary.tags + summary.keywords)
            return haystack.contains { $0.localizedStandardContains(terms) }
        }
    }

    /// Stores the unfiltered first library page. Saved summaries in the time range the page covers
    /// but missing from it were deleted (or unshared) elsewhere, so they are dropped; older ones
    /// are kept unless the page is the whole library.
    public func replaceFirstPage(_ page: [Summary], isComplete: Bool) {
        let ids = Set(page.map(\.id))
        let oldest = page.map(\.activityDate).min()
        let older = isComplete ? [] : summaries.filter { saved in
            guard !ids.contains(saved.id) else { return false }
            guard let oldest else { return true }
            return saved.activityDate < oldest
        }
        commit(page + older)
    }

    public func upsert(_ summary: Summary) {
        upsert([summary])
    }

    public func upsert(_ fresh: [Summary]) {
        guard !fresh.isEmpty else { return }
        let ids = Set(fresh.map(\.id))
        commit(fresh + summaries.filter { !ids.contains($0.id) })
    }

    public func remove(id: String) {
        guard summaries.contains(where: { $0.id == id }) else { return }
        commit(summaries.filter { $0.id != id })
    }

    /// Bytes the saved summaries take on disk.
    public var fileSize: Int {
        guard let fileURL else { return 0 }
        return (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
    }

    public func clear() {
        summaries = []
        guard let fileURL else { return }
        writer.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func commit(_ items: [Summary]) {
        summaries = Array(items.sorted { $0.activityDate > $1.activityDate }.prefix(Self.capacity))
        guard let fileURL, let data = try? SummaryJSON.encoder().encode(summaries) else { return }
        writer.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

extension Error {
    /// True when a request failed because the device can't reach the server.
    public var isOffline: Bool {
        guard let error = self as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                .timedOut, .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed].contains(error.code)
    }
}
