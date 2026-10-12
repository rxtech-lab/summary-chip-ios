import Foundation

/// Where a review comment stands. Mirrors `PAPER_REVIEW_STATUSES` (`server/lib/contracts/paper-review.ts`).
public enum PaperReviewStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Waiting for an agent to edit the paper.
    case open
    /// An agent edited the paper for it; the owner hasn't looked at the change yet.
    case addressed
    /// The owner accepted the change.
    case resolved

    public init(from decoder: any Decoder) throws {
        // A newer server's status reads as waiting rather than failing the list.
        self = PaperReviewStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .open
    }

    public var title: String {
        switch self {
        case .open: String(localized: "Waiting for your agent", bundle: .module, comment: "Paper review status")
        case .addressed: String(localized: "Ready to review", bundle: .module, comment: "Paper review status")
        case .resolved: String(localized: "Finished", bundle: .module, comment: "Paper review status")
        }
    }

    public var systemImage: String {
        switch self {
        case .open: "bubble.left"
        case .addressed: "checkmark.bubble"
        case .resolved: "checkmark.circle.fill"
        }
    }
}

/// A comment the owner left on a passage of their paper in the reader (`docs/papers.md` → Reviews):
/// the quoted passage and what to change. An agent that edits the paper for it marks it
/// `addressed`, recording the version holding its edits, so the change can be read as a diff
/// from `version` to `addressedVersion`.
public struct PaperReview: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var paperId: String
    /// The paper file the passage is in, when the reader knew it.
    public var file: String?
    public var quote: String
    public var comment: String
    public var status: PaperReviewStatus
    /// The paper's version the comment was made on.
    public var version: Int
    /// The version holding the agent's edits; nil until it is addressed.
    public var addressedVersion: Int?
    /// What the agent said it changed.
    public var agentNote: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var addressedAt: Date?
    public var resolvedAt: Date?

    public init(
        id: String, paperId: String, file: String? = nil, quote: String, comment: String, status: PaperReviewStatus = .open,
        version: Int, addressedVersion: Int? = nil, agentNote: String? = nil, createdAt: Date = .now, updatedAt: Date = .now,
        addressedAt: Date? = nil, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.paperId = paperId
        self.file = file
        self.quote = quote
        self.comment = comment
        self.status = status
        self.version = version
        self.addressedVersion = addressedVersion
        self.agentNote = agentNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.addressedAt = addressedAt
        self.resolvedAt = resolvedAt
    }

    /// The change can be read once the agent recorded the version holding it.
    public var hasChanges: Bool { addressedVersion != nil && addressedVersion != version }
    public var isUnresolved: Bool { status != .resolved }
}

/// `POST /api/v1/papers/:id/reviews`.
public struct PaperReviewDraft: Encodable, Sendable, Hashable {
    public var quote: String
    public var comment: String
    public var file: String?

    public init(quote: String, comment: String, file: String? = nil) {
        self.quote = quote
        self.comment = comment
        self.file = file
    }
}
