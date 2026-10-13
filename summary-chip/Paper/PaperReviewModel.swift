import Foundation
import Observation
import SummaryKit

/// Where a paper's reviews are kept: the server for a real paper, canned data for previews.
protocol PaperReviewBackend: Sendable {
    func list() async throws -> [PaperReview]
    func create(_ draft: PaperReviewDraft) async throws -> PaperReview
    func update(id: String, status: PaperReviewStatus?, comment: String?) async throws -> PaperReview
    func delete(id: String) async throws
    /// A saved version's source, for the diff an agent's edits make.
    func source(version: Int) async throws -> PaperSource
}

struct APIPaperReviewBackend: PaperReviewBackend {
    let api: SummaryAPIClient
    let paperID: String

    func list() async throws -> [PaperReview] { try await api.paperReviews(id: paperID) }
    func create(_ draft: PaperReviewDraft) async throws -> PaperReview { try await api.createPaperReview(id: paperID, draft: draft) }
    func update(id: String, status: PaperReviewStatus?, comment: String?) async throws -> PaperReview {
        try await api.updatePaperReview(id: paperID, reviewId: id, status: status, comment: comment)
    }
    func delete(id: String) async throws { try await api.deletePaperReview(id: paperID, reviewId: id) }
    func source(version: Int) async throws -> PaperSource {
        guard case .paper(let source) = try await api.version(id: paperID, number: version).content else {
            throw PaperProjectError(String(localized: "Version \(version) isn't a paper."))
        }
        return source
    }
}

/// The reviews of one paper (`docs/papers.md` → Reviews): the comments the owner left on passages
/// in the reader, which agents address over MCP. Polled with the paper, so an agent's "finished"
/// shows up while the paper is open.
@Observable
@MainActor
final class PaperReviewModel {
    let backend: any PaperReviewBackend
    private(set) var reviews: [PaperReview] = []
    private(set) var loaded = false
    private(set) var loadError: String?
    /// Bumped when a review is added or finished, for haptics.
    private(set) var changeCount = 0
    @ObservationIgnored private var sources: [Int: PaperSource] = [:]

    init(backend: any PaperReviewBackend) {
        self.backend = backend
    }

    var open: [PaperReview] { reviews.filter { $0.status == .open } }
    /// Addressed by an agent and waiting for the owner to read the change.
    var ready: [PaperReview] { reviews.filter { $0.status == .addressed } }
    var resolved: [PaperReview] { reviews.filter { $0.status == .resolved } }
    var unresolved: [PaperReview] { reviews.filter(\.isUnresolved) }

    func load() async {
        do {
            let fresh = try await backend.list()
            let readyNow = fresh.filter({ $0.status == .addressed }).count
            if loaded, fresh != reviews, readyNow > ready.count { changeCount += 1 }
            reviews = fresh
            loaded = true
            loadError = nil
        } catch is CancellationError {
        } catch {
            if !loaded { loadError = error.localizedDescription }
        }
    }

    /// Adds a comment on `quote`. The file is the one whose source holds the passage, when just one does.
    func add(quote: String, comment: String, in source: PaperSource?) async throws -> PaperReview {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = (source?.files ?? []).filter { !$0.isImage && $0.content.contains(trimmed) }
        let review = try await backend.create(PaperReviewDraft(quote: trimmed, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines), file: files.count == 1 ? files[0].path : nil))
        reviews.append(review)
        changeCount += 1
        return review
    }

    /// The owner accepts the agent's change.
    func resolve(_ review: PaperReview) async throws {
        replace(try await backend.update(id: review.id, status: .resolved, comment: nil))
        changeCount += 1
    }

    /// Asks the agent again; its earlier edits stay in the history.
    func reopen(_ review: PaperReview, comment: String? = nil) async throws {
        replace(try await backend.update(id: review.id, status: .open, comment: comment))
    }

    func delete(_ review: PaperReview) async throws {
        try await backend.delete(id: review.id)
        reviews.removeAll { $0.id == review.id }
    }

    /// What the agent changed for the review: its version against the one the comment was made on.
    func diff(for review: PaperReview) async throws -> PaperDiff {
        guard let addressed = review.addressedVersion else { throw PaperProjectError(String(localized: "Your agent hasn't finished this review yet.")) }
        let before = try await source(version: review.version)
        let after = try await source(version: addressed)
        return PaperDiff(old: before, new: after)
    }

    private func source(version: Int) async throws -> PaperSource {
        if let cached = sources[version] { return cached }
        let source = try await backend.source(version: version)
        sources[version] = source
        return source
    }

    private func replace(_ review: PaperReview) {
        if let index = reviews.firstIndex(where: { $0.id == review.id }) { reviews[index] = review } else { reviews.append(review) }
    }
}
