import Foundation

/// How a summary's content was submitted. Mirrors `sourceType` in the contract.
public enum SummarySourceType: String, Codable, Sendable, CaseIterable {
    case url
    case webpage
    case pdf
    case text
    /// A file on the owner's device; the server keeps only the summary, never its content.
    case local

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SummarySourceType(rawValue: raw) ?? .url
    }

    public var systemImage: String {
        switch self {
        case .url, .webpage: "safari"
        case .pdf: "doc.richtext"
        case .text: "text.alignleft"
        case .local: "doc"
        }
    }
}

/// What kind of content a summary was made from. Mirrors `source` in the contract; a `url`
/// submission that served a PDF is `.pdf`, and a page on X, Facebook, YouTube or GitHub is labelled
/// with that platform. Unknown future kinds decode as `.other`.
public enum SummaryOrigin: Codable, Sendable, Hashable, Identifiable {
    case web
    case pdf
    case text
    case x
    case facebook
    case youtube
    case github
    case other(String)

    /// Every kind the server knows, in the order the library's source filter lists them.
    public static let known: [SummaryOrigin] = [.web, .x, .facebook, .youtube, .github, .pdf, .text]

    public var id: String { rawValue }

    public init(rawValue: String) {
        switch rawValue {
        case "web": self = .web
        case "pdf": self = .pdf
        case "text": self = .text
        case "x": self = .x
        case "facebook": self = .facebook
        case "youtube": self = .youtube
        case "github": self = .github
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .web: "web"
        case .pdf: "pdf"
        case .text: "text"
        case .x: "x"
        case .facebook: "facebook"
        case .youtube: "youtube"
        case .github: "github"
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

    /// Older payloads without `source` infer it from how the content was submitted.
    public init(_ sourceType: SummarySourceType) {
        switch sourceType {
        case .url, .webpage: self = .web
        case .pdf: self = .pdf
        case .text, .local: self = .text
        }
    }

    public var title: String {
        switch self {
        case .web: "Web"
        case .pdf: "PDF"
        case .text: "Text"
        case .x: "X"
        case .facebook: "Facebook"
        case .youtube: "YouTube"
        case .github: "GitHub"
        case .other(let raw): raw.capitalized
        }
    }

    public var systemImage: String {
        switch self {
        case .web: "safari"
        case .pdf: "doc.richtext"
        case .text: "text.alignleft"
        case .x: "bubble.left"
        case .facebook: "person.2"
        case .youtube: "play.rectangle"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
}

public enum ImageStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case graphic
    case illustration

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ImageStyle(rawValue: raw) ?? .graphic
    }

    public var title: String {
        switch self {
        case .graphic: "Graphic"
        case .illustration: "Illustration"
        }
    }

    public var detail: String {
        switch self {
        case .graphic: "Abstract shapes and gradients that match the topic."
        case .illustration: "An AI illustration behind the headline."
        }
    }

    public var systemImage: String {
        switch self {
        case .graphic: "square.on.circle"
        case .illustration: "paintbrush.pointed"
        }
    }
}

public enum SummaryVisibility: String, Codable, Sendable, CaseIterable, Identifiable {
    case `public`
    case `private`

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SummaryVisibility(rawValue: raw) ?? .public
    }

    public var title: String {
        switch self {
        case .public: "Public"
        case .private: "Private"
        }
    }

    public var systemImage: String {
        switch self {
        case .public: "globe"
        case .private: "lock.fill"
        }
    }
}

public enum ThemeMode: String, Codable, Sendable {
    case light
    case dark

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThemeMode(rawValue: raw) ?? .dark
    }
}

public struct Theme: Codable, Sendable, Hashable {
    public var colors: [String]
    public var mode: ThemeMode
    public var emoji: String
    public var accent: String

    public init(colors: [String], mode: ThemeMode, emoji: String, accent: String) {
        self.colors = colors
        self.mode = mode
        self.emoji = emoji
        self.accent = accent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? []
        mode = try c.decodeIfPresent(ThemeMode.self, forKey: .mode) ?? .dark
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "📰"
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? colors.first ?? "#104b8f"
    }

    public static let fallback = Theme(
        colors: ["#104b8f", "#18673c", "#efcabc", "#9e8d80", "#5c3e34", "#dec5c6"],
        mode: .dark,
        emoji: "📰",
        accent: "#104b8f"
    )
}

/// A generated summary, exactly as the contract's `Summary` JSON shape.
public struct Summary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    public var shareUrl: URL
    public var ogImageUrl: URL?
    /// The OG artwork without any text; nil for summaries created before it existed.
    public var artImageUrl: URL?
    public var sourceType: SummarySourceType
    public var source: SummaryOrigin
    public var sourceUrl: URL?
    public var sourceTitle: String?
    public var siteName: String?
    public var sourceFileUrl: URL?
    public var title: String
    public var summary: String
    public var highlights: [String]
    public var category: String
    public var tags: [String]
    public var keywords: [String]
    public var language: String
    public var theme: Theme
    public var imageStyle: ImageStyle
    public var visibility: SummaryVisibility
    public var ttlDays: Int?
    public var expiresAt: Date?
    public var viewCount: Int
    public var isOwner: Bool
    /// When the user last opened this (someone else's) summary; nil for their own.
    public var viewedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, slug: String, shareUrl: URL, ogImageUrl: URL?, artImageUrl: URL? = nil, sourceType: SummarySourceType,
        source: SummaryOrigin? = nil, sourceUrl: URL?, sourceTitle: String?, siteName: String?, sourceFileUrl: URL?,
        title: String, summary: String, highlights: [String], category: String, tags: [String],
        keywords: [String], language: String, theme: Theme, imageStyle: ImageStyle,
        visibility: SummaryVisibility, ttlDays: Int?, expiresAt: Date?, viewCount: Int,
        isOwner: Bool, viewedAt: Date? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.id = id; self.slug = slug; self.shareUrl = shareUrl; self.ogImageUrl = ogImageUrl; self.artImageUrl = artImageUrl
        self.sourceType = sourceType; self.source = source ?? SummaryOrigin(sourceType); self.sourceUrl = sourceUrl; self.sourceTitle = sourceTitle
        self.siteName = siteName; self.sourceFileUrl = sourceFileUrl; self.title = title
        self.summary = summary; self.highlights = highlights; self.category = category
        self.tags = tags; self.keywords = keywords; self.language = language; self.theme = theme
        self.imageStyle = imageStyle; self.visibility = visibility; self.ttlDays = ttlDays
        self.expiresAt = expiresAt; self.viewCount = viewCount; self.isOwner = isOwner
        self.viewedAt = viewedAt; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Tolerant decoding: the public API omits owner-only fields, so everything that is not
    /// needed to render a summary falls back to a sensible default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        shareUrl = try c.decode(URL.self, forKey: .shareUrl)
        ogImageUrl = try c.decodeLenientURL(forKey: .ogImageUrl)
        artImageUrl = try c.decodeLenientURL(forKey: .artImageUrl)
        sourceType = try c.decodeIfPresent(SummarySourceType.self, forKey: .sourceType) ?? .url
        source = try c.decodeIfPresent(SummaryOrigin.self, forKey: .source) ?? SummaryOrigin(sourceType)
        sourceUrl = try c.decodeLenientURL(forKey: .sourceUrl)
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        sourceFileUrl = try c.decodeLenientURL(forKey: .sourceFileUrl)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        highlights = try c.decodeIfPresent([String].self, forKey: .highlights) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .fallback
        imageStyle = try c.decodeIfPresent(ImageStyle.self, forKey: .imageStyle) ?? .graphic
        visibility = try c.decodeIfPresent(SummaryVisibility.self, forKey: .visibility) ?? .public
        ttlDays = try c.decodeIfPresent(Int.self, forKey: .ttlDays)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount) ?? 0
        isOwner = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        viewedAt = try c.decodeIfPresent(Date.self, forKey: .viewedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// The date the library sorts by: when you created it, or when you last opened someone else's.
    public var activityDate: Date { viewedAt ?? createdAt }

    /// Image for tiles that draw their own title: the text-free artwork, else the OG card.
    public var tileImageUrl: URL? { artImageUrl ?? ogImageUrl }

    /// The URL "Read the original" opens: the source page, or the uploaded PDF.
    public var originalURL: URL? { sourceUrl ?? sourceFileUrl }

    /// Short attribution used under titles ("The Verge", "example.com", "PDF").
    public var sourceLabel: String {
        if let siteName, !siteName.isEmpty { return siteName }
        if let host = sourceUrl?.host() { return host.replacingOccurrences(of: "www.", with: "") }
        return source.title
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

extension KeyedDecodingContainer {
    /// Decodes a URL but treats empty strings / unparsable values as `nil` rather than failing
    /// the entire summary.
    func decodeLenientURL(forKey key: Key) throws -> URL? {
        guard let raw = try decodeIfPresent(String.self, forKey: key),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// `{items:[Summary], nextCursor}` from `GET /api/v1/summaries`.
public struct SummaryPage: Codable, Sendable {
    public var items: [Summary]
    public var nextCursor: String?

    public init(items: [Summary], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct FacetCount: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var count: Int
    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// `GET /api/v1/facets`.
public struct Facets: Codable, Sendable, Hashable {
    public var categories: [FacetCount]
    public var tags: [FacetCount]

    public init(categories: [FacetCount] = [], tags: [FacetCount] = []) {
        self.categories = categories
        self.tags = tags
    }
}

/// Which facet list `GET /api/v1/facets?kind=…` searches.
public enum FacetKind: String, Sendable, Hashable {
    case category, tag
}

/// `GET /api/v1/facets?kind=…&q=…`: one page of a facet list, most used first.
public struct FacetPage: Codable, Sendable, Hashable {
    public var items: [FacetCount]
    public var nextCursor: String?

    public init(items: [FacetCount] = [], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// `201 {key, uploadUrl, method:"PUT", headers, expiresAt}` from `POST /api/v1/uploads`.
public struct UploadTicket: Codable, Sendable, Hashable {
    public var key: String
    public var uploadUrl: URL
    public var method: String
    public var headers: [String: String]
    public var expiresAt: Date?

    public init(key: String, uploadUrl: URL, method: String = "PUT", headers: [String: String] = [:], expiresAt: Date? = nil) {
        self.key = key
        self.uploadUrl = uploadUrl
        self.method = method
        self.headers = headers
        self.expiresAt = expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        uploadUrl = try c.decode(URL.self, forKey: .uploadUrl)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "PUT"
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

public struct CreateUploadRequest: Codable, Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    public var byteSize: Int

    public init(filename: String, mimeType: String = "application/pdf", byteSize: Int) {
        self.filename = filename
        self.mimeType = mimeType
        self.byteSize = byteSize
    }
}

/// The closed category list from the contract.
public enum SummaryCategory {
    public static let all = [
        "Technology", "Science", "Business", "Finance", "Politics", "World", "Health", "Sports",
        "Entertainment", "Culture", "Education", "Lifestyle", "Travel", "Food", "Opinion",
        "Research", "Other",
    ]
}
