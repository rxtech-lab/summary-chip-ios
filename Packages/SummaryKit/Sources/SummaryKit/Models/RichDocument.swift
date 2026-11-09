import Foundation

/// A rich document: blocks rendered top to bottom. Mirrors `server/lib/contracts/rich-document.ts`;
/// spec: `docs/rich-documents.md`.
public struct RichDocumentContent: Codable, Sendable, Hashable {
    public var version: Int
    public var title: String
    public var description: String?
    public var blocks: [RichBlock]

    public init(version: Int = 1, title: String, description: String? = nil, blocks: [RichBlock] = []) {
        self.version = version
        self.title = title
        self.description = description
        self.blocks = blocks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        blocks = try c.decodeIfPresent([RichBlock].self, forKey: .blocks) ?? []
    }
}

/// What a block shows. Unknown future types decode as `.other` and are skipped by the renderer.
public enum RichBlockType: Codable, Sendable, Hashable {
    case text, image, video, audio
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "text": self = .text
        case "image": self = .image
        case "video": self = .video
        case "audio": self = .audio
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .text: "text"
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .other(let raw): raw
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

public enum RichBlockAlignment: String, Codable, Sendable, Hashable {
    case leading, center, trailing

    public init(from decoder: any Decoder) throws {
        self = RichBlockAlignment(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .leading
    }
}

/// One column of a block: `markdown` for text, `url` (plus caption, alt, poster) for media.
public struct RichColumn: Codable, Sendable, Hashable {
    public var markdown: String?
    public var url: URL?
    public var posterUrl: URL?
    public var alt: String?
    public var caption: String?

    public init(markdown: String? = nil, url: URL? = nil, posterUrl: URL? = nil, alt: String? = nil, caption: String? = nil) {
        self.markdown = markdown
        self.url = url
        self.posterUrl = posterUrl
        self.alt = alt
        self.caption = caption
    }
}

/// Shown under a block. Only links exist today; unknown child types are skipped.
public struct RichChild: Codable, Sendable, Hashable {
    public var type: String
    public var title: String?
    public var url: URL?

    public init(type: String = "link", title: String?, url: URL?) {
        self.type = type
        self.title = title
        self.url = url
    }

    /// A link the renderer can show.
    public var link: (title: String, url: URL)? {
        guard type == "link", let title, let url else { return nil }
        return (title, url)
    }
}

public struct RichBlock: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: RichBlockType
    public var align: RichBlockAlignment
    /// One, or two side by side.
    public var columns: [RichColumn]
    public var children: [RichChild]

    public init(id: String, type: RichBlockType, align: RichBlockAlignment = .leading, columns: [RichColumn], children: [RichChild] = []) {
        self.id = id
        self.type = type
        self.align = align
        self.columns = columns
        self.children = children
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(RichBlockType.self, forKey: .type)
        align = try c.decodeIfPresent(RichBlockAlignment.self, forKey: .align) ?? .leading
        columns = try c.decodeIfPresent([RichColumn].self, forKey: .columns) ?? []
        children = try c.decodeIfPresent([RichChild].self, forKey: .children) ?? []
    }
}

/// `GET /api/v1/rich-documents/:id`.
public struct RichDocument: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    /// Bumped on every save.
    public var revision: Int
    public var visibility: SummaryVisibility
    public var isOwner: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var shareUrl: URL?
    public var document: RichDocumentContent

    public init(id: String, slug: String, revision: Int = 0, visibility: SummaryVisibility = .private, isOwner: Bool = true, createdAt: Date = .now, updatedAt: Date = .now, shareUrl: URL? = nil, document: RichDocumentContent) {
        self.id = id
        self.slug = slug
        self.revision = revision
        self.visibility = visibility
        self.isOwner = isOwner
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.shareUrl = shareUrl
        self.document = document
    }
}
