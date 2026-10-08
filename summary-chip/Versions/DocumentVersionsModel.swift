import Foundation
import Observation
import SummaryKit

/// The saved versions of one of the owner's library items (a summary or a trip), and the one being
/// looked at instead of the current content. The detail view shows `preview` read-only until the
/// owner goes back to the current version or restores it.
@Observable
final class DocumentVersionsModel {
    /// How many versions the toolbar menu lists; the rest are in the full history.
    static let menuLimit = 8

    let api: SummaryAPIClient
    let id: String
    private(set) var versions: [DocumentVersion] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    /// The past version shown instead of the current content; nil shows the current one.
    private(set) var preview: DocumentVersionDetail?
    /// A version being fetched to show.
    private(set) var loadingVersion: Int?
    private(set) var isRestoring = false
    /// Bumped on each restore and on each version switch, for haptics.
    private(set) var restoredCount = 0
    private(set) var switchCount = 0
    var errorMessage: String?
    var showsHistory = false
    var confirmsRestore = false
    /// The history sheet is up (it shows its own loading status).
    var isHistoryOpen = false

    init(api: SummaryAPIClient, id: String) {
        self.api = api
        self.id = id
    }

    var current: DocumentVersion? { versions.first(where: \.isCurrent) }
    /// The version on screen: the previewed one, else the current one.
    var shownVersion: Int? { preview?.info.version ?? current?.version }
    var isPreviewing: Bool { preview != nil }
    var isBusy: Bool { loadingVersion != nil || isRestoring }
    /// The newest versions besides the current one, for the toolbar menu.
    var recentPast: [DocumentVersion] { Array(versions.filter { !$0.isCurrent }.prefix(Self.menuLimit)) }

    /// Reloads the newest page, after the item changed (an edit here, a restore, an agent's save).
    func reload() async {
        guard let page = try? await api.versions(id: id, limit: 30) else { return }
        versions = page.items
        nextCursor = page.nextCursor
        // A version that has since become the current one isn't a preview any more.
        if preview?.info.version == current?.version { preview = nil }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.versions(id: id, cursor: cursor, limit: 30)
            versions += page.items.filter { item in !versions.contains { $0.version == item.version } }
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows `version` in place of the current content; the current version (or nil) goes back to it.
    func show(_ version: Int?) async {
        guard let version, version != current?.version else {
            if preview != nil { switchCount += 1 }
            preview = nil
            return
        }
        guard version != preview?.info.version, loadingVersion == nil else { return }
        loadingVersion = version
        defer { loadingVersion = nil }
        do {
            preview = try await api.version(id: id, number: version)
            switchCount += 1
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Restores the previewed version as the newest one. Returns the item as restored.
    func restorePreview() async -> DocumentVersionRestore? {
        guard let number = preview?.info.version, !isRestoring else { return nil }
        isRestoring = true
        defer { isRestoring = false }
        do {
            let restored = try await api.restoreVersion(id: id, number: number)
            preview = nil
            restoredCount += 1
            await reload()
            return restored
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

extension DocumentVersion {
    var label: String { String(localized: "Version \(version)") }

    /// "Oct 9, 2026 at 14:05 · Your agent".
    var detail: String {
        "\(createdAt.formatted(date: .abbreviated, time: .shortened)) · \(actorLabel)"
    }

    var actorLabel: String {
        switch actor {
        case .owner: String(localized: "You")
        case .agent: String(localized: "Your agent")
        case .chat: String(localized: "Chippy chat")
        case .source: String(localized: "Trip agent")
        case .restore:
            if let restoredFrom { String(localized: "Restored version \(restoredFrom)") } else { String(localized: "Restored") }
        case .other: String(localized: "Edited")
        }
    }

    var systemImage: String {
        switch actor {
        case .owner: "person"
        case .agent, .source: "cpu"
        case .chat: "sparkles"
        case .restore: "clock.arrow.circlepath"
        case .other: "pencil"
        }
    }
}
