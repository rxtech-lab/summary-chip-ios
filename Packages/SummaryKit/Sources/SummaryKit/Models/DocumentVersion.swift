import Foundation

/// Who saved a version of a library item.
public enum DocumentVersionActor: Codable, Sendable, Hashable {
    /// The owner, in the app.
    case owner
    /// One of the owner's agents, over MCP.
    case agent
    /// The in-app chat.
    case chat
    /// The trip agent, reading a page or text shared to a trip.
    case source
    /// A restore of an earlier version.
    case restore
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "owner": self = .owner
        case "agent": self = .agent
        case "chat": self = .chat
        case "source": self = .source
        case "restore": self = .restore
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .owner: "owner"
        case .agent: "agent"
        case .chat: "chat"
        case .source: "source"
        case .restore: "restore"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One saved state of a summary's text or a trip's document (`GET /api/v1/summaries/:id/versions`).
/// Every content edit adds one; sharing, language and cover changes don't.
public struct DocumentVersion: Codable, Sendable, Hashable, Identifiable {
    public var version: Int
    public var kind: SummaryKind
    public var actor: DocumentVersionActor
    /// The version a restore brought back.
    public var restoredFrom: Int?
    public var createdAt: Date
    /// The item's title in this version.
    public var title: String
    /// The version the item is at now.
    public var isCurrent: Bool

    public var id: Int { version }

    public init(version: Int, kind: SummaryKind, actor: DocumentVersionActor, restoredFrom: Int? = nil, createdAt: Date, title: String, isCurrent: Bool) {
        self.version = version
        self.kind = kind
        self.actor = actor
        self.restoredFrom = restoredFrom
        self.createdAt = createdAt
        self.title = title
        self.isCurrent = isCurrent
    }
}

/// `{items, nextCursor}` from `GET /api/v1/summaries/:id/versions`, newest first.
public struct DocumentVersionPage: Codable, Sendable, Hashable {
    public var items: [DocumentVersion]
    public var nextCursor: String?

    public init(items: [DocumentVersion], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// What a summary's version keeps: its text as written.
public struct SummaryVersionContent: Codable, Sendable, Hashable {
    public var title: String
    public var summary: String
    public var highlights: [String]
    public var category: String
    public var tags: [String]
    public var keywords: [String]

    public init(title: String, summary: String, highlights: [String], category: String, tags: [String], keywords: [String]) {
        self.title = title
        self.summary = summary
        self.highlights = highlights
        self.category = category
        self.tags = tags
        self.keywords = keywords
    }
}

/// A version's content, by the item's kind.
public enum DocumentVersionContent: Sendable, Hashable {
    case summary(SummaryVersionContent)
    case trip(TripDocument)
    /// A kind this build doesn't know; it can be listed and restored, not shown.
    case unsupported
}

/// `GET /api/v1/summaries/:id/versions/:version`: one version with its content.
public struct DocumentVersionDetail: Decodable, Sendable, Hashable, Identifiable {
    public var info: DocumentVersion
    public var content: DocumentVersionContent

    public var id: Int { info.version }

    public init(info: DocumentVersion, content: DocumentVersionContent) {
        self.info = info
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case content }
    private struct TripContent: Decodable { let document: TripDocument }

    public init(from decoder: any Decoder) throws {
        info = try DocumentVersion(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch info.kind {
        case .summary: content = .summary(try c.decode(SummaryVersionContent.self, forKey: .content))
        case .trip: content = .trip(try c.decode(TripContent.self, forKey: .content).document)
        case .other: content = .unsupported
        }
    }
}

/// `POST /api/v1/summaries/:id/versions/:version/restore`: the item as restored, under its kind.
public struct DocumentVersionRestore: Decodable, Sendable, Hashable {
    /// The version the restore added; nil when the item already matched.
    public var version: DocumentVersion?
    public var summary: Summary?
    public var trip: Trip?

    public init(version: DocumentVersion?, summary: Summary? = nil, trip: Trip? = nil) {
        self.version = version
        self.summary = summary
        self.trip = trip
    }
}

public extension Summary {
    /// This summary showing a version's text instead of its own, as written.
    func showing(_ content: SummaryVersionContent) -> Summary {
        var copy = self
        copy.title = content.title
        copy.summary = content.summary
        copy.highlights = content.highlights
        copy.category = content.category
        copy.displayCategory = content.category
        copy.tags = content.tags
        copy.displayTags = content.tags
        copy.keywords = content.keywords
        copy.language = originalLanguage
        copy.translationPending = false
        return copy
    }
}
