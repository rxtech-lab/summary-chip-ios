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
        case .web: String(localized: "Web", bundle: .module, comment: "Summary source kind: a web page")
        case .pdf: String(localized: "PDF", bundle: .module)
        case .text: String(localized: "Text", bundle: .module, comment: "Summary source kind: pasted text")
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

    /// Name of the bundled brand logo for platform sources; `nil` falls back to `systemImage`.
    public var brandImage: String? {
        switch self {
        case .x: "source.x"
        case .facebook: "source.facebook"
        case .youtube: "source.youtube"
        case .github: "source.github"
        default: nil
        }
    }
}

/// What a library item is: a summary card, or a trip diary (`/api/v1/trips/:id`, same id).
/// Mirrors `kind` in the contract; older payloads without it are summaries, unknown kinds decode as `.other`.
public enum SummaryKind: Codable, Sendable, Hashable, Identifiable {
    case summary
    case trip
    case other(String)

    /// Every kind the server knows, in the order the library's filter lists them.
    public static let known: [SummaryKind] = [.summary, .trip]

    public var id: String { rawValue }

    public init(rawValue: String) {
        switch rawValue {
        case "summary": self = .summary
        case "trip": self = .trip
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .summary: "summary"
        case .trip: "trip"
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

    public var title: String {
        switch self {
        case .summary: String(localized: "Summaries", bundle: .module, comment: "Library kind filter: summary cards")
        case .trip: String(localized: "Trips", bundle: .module, comment: "Library kind filter: trip diaries")
        case .other(let raw): raw.capitalized
        }
    }

    public var systemImage: String {
        switch self {
        case .summary: "text.quote"
        case .trip: "map"
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
        case .graphic: String(localized: "Graphic", bundle: .module, comment: "Image style option")
        case .illustration: String(localized: "Illustration", bundle: .module, comment: "Image style option")
        }
    }

    public var detail: String {
        switch self {
        case .graphic: String(localized: "Abstract shapes and gradients that match the topic.", bundle: .module)
        case .illustration: String(localized: "An AI illustration behind the headline.", bundle: .module)
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
        case .public: String(localized: "Public", bundle: .module, comment: "Summary visibility")
        case .private: String(localized: "Private", bundle: .module, comment: "Summary visibility")
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
    /// `.trip` items open as a trip diary; their structured data lives at `/api/v1/trips/:id`.
    public var kind: SummaryKind
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
    /// The source was kept as Markdown; read it with `SummaryAPIClient.sourceMarkdown(id:)`.
    public var hasSourceMarkdown: Bool
    /// The server is still formatting the source; refresh the summary until `hasSourceMarkdown`.
    public var sourceMarkdownPending: Bool
    public var title: String
    public var summary: String
    public var highlights: [String]
    public var category: String
    public var tags: [String]
    /// Chip labels in the reading language; canonical category and tags remain filter/edit values.
    public var displayCategory: String
    public var displayTags: [String]
    public var keywords: [String]
    /// The language `title`, `summary` and `highlights` are in: a translation's, else `originalLanguage`.
    public var language: String
    /// The language the summary was written in.
    public var originalLanguage: String
    /// Owner only: the language they chose to read it in (`PATCH displayLanguage`); nil = as written.
    public var displayLanguage: String?
    /// A translation into the reader's language is being written; fetch it again shortly.
    public var translationPending: Bool
    /// The translated source document is being written; the original is served until then.
    public var sourceTranslationPending: Bool
    public var theme: Theme
    public var imageStyle: ImageStyle
    public var visibility: SummaryVisibility
    public var ttlDays: Int?
    public var expiresAt: Date?
    public var viewCount: Int
    public var isOwner: Bool
    /// When the user last opened this (someone else's) summary; nil for their own.
    public var viewedAt: Date?
    /// When the user starred this summary (it's listed under Likes); nil when not starred.
    public var likedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, kind: SummaryKind = .summary, slug: String, shareUrl: URL, ogImageUrl: URL?, artImageUrl: URL? = nil, sourceType: SummarySourceType,
        source: SummaryOrigin? = nil, sourceUrl: URL?, sourceTitle: String?, siteName: String?, sourceFileUrl: URL?,
        hasSourceMarkdown: Bool = false, sourceMarkdownPending: Bool = false, title: String, summary: String, highlights: [String], category: String, tags: [String],
        keywords: [String], language: String, displayCategory: String? = nil, displayTags: [String]? = nil,
        originalLanguage: String? = nil, displayLanguage: String? = nil,
        translationPending: Bool = false, sourceTranslationPending: Bool = false, theme: Theme, imageStyle: ImageStyle,
        visibility: SummaryVisibility, ttlDays: Int?, expiresAt: Date?, viewCount: Int,
        isOwner: Bool, viewedAt: Date? = nil, likedAt: Date? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.id = id; self.kind = kind; self.slug = slug; self.shareUrl = shareUrl; self.ogImageUrl = ogImageUrl; self.artImageUrl = artImageUrl
        self.sourceType = sourceType; self.source = source ?? SummaryOrigin(sourceType); self.sourceUrl = sourceUrl; self.sourceTitle = sourceTitle
        self.siteName = siteName; self.sourceFileUrl = sourceFileUrl; self.hasSourceMarkdown = hasSourceMarkdown
        self.sourceMarkdownPending = sourceMarkdownPending; self.title = title
        self.summary = summary; self.highlights = highlights; self.category = category
        self.tags = tags; self.keywords = keywords; self.language = language
        self.displayCategory = displayCategory ?? category
        self.displayTags = displayTags?.count == tags.count ? (displayTags ?? tags) : tags
        self.originalLanguage = originalLanguage ?? language; self.displayLanguage = displayLanguage
        self.translationPending = translationPending; self.sourceTranslationPending = sourceTranslationPending
        self.theme = theme
        self.imageStyle = imageStyle; self.visibility = visibility; self.ttlDays = ttlDays
        self.expiresAt = expiresAt; self.viewCount = viewCount; self.isOwner = isOwner
        self.viewedAt = viewedAt; self.likedAt = likedAt; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Tolerant decoding: the public API omits owner-only fields, so everything that is not
    /// needed to render a summary falls back to a sensible default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(SummaryKind.self, forKey: .kind) ?? .summary
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
        hasSourceMarkdown = try c.decodeIfPresent(Bool.self, forKey: .hasSourceMarkdown) ?? false
        sourceMarkdownPending = try c.decodeIfPresent(Bool.self, forKey: .sourceMarkdownPending) ?? false
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        highlights = try c.decodeIfPresent([String].self, forKey: .highlights) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        displayCategory = try c.decodeIfPresent(String.self, forKey: .displayCategory) ?? category
        let tagLabels = try c.decodeIfPresent([String].self, forKey: .displayTags)
        displayTags = tagLabels?.count == tags.count ? (tagLabels ?? tags) : tags
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        originalLanguage = try c.decodeIfPresent(String.self, forKey: .originalLanguage) ?? language
        displayLanguage = try c.decodeIfPresent(String.self, forKey: .displayLanguage)
        translationPending = try c.decodeIfPresent(Bool.self, forKey: .translationPending) ?? false
        sourceTranslationPending = try c.decodeIfPresent(Bool.self, forKey: .sourceTranslationPending) ?? false
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .fallback
        imageStyle = try c.decodeIfPresent(ImageStyle.self, forKey: .imageStyle) ?? .graphic
        visibility = try c.decodeIfPresent(SummaryVisibility.self, forKey: .visibility) ?? .public
        ttlDays = try c.decodeIfPresent(Int.self, forKey: .ttlDays)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount) ?? 0
        isOwner = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        viewedAt = try c.decodeIfPresent(Date.self, forKey: .viewedAt)
        likedAt = try c.decodeIfPresent(Date.self, forKey: .likedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// Starred by the user, so it appears under Likes.
    public var isLiked: Bool { likedAt != nil }

    /// The title, summary and key points are shown translated from `originalLanguage`.
    public var isTranslated: Bool { language != originalLanguage }

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

/// `{markdown, language, translationPending}` from `GET /api/v1/summaries/:id/markdown`.
public struct SourceMarkdown: Codable, Sendable, Hashable {
    public var markdown: String
    /// The language `markdown` is in; nil from servers that predate translations.
    public var language: String?
    /// The document is being translated into the reader's language; `markdown` is the original until then.
    public var translationPending: Bool

    public init(markdown: String, language: String? = nil, translationPending: Bool = false) {
        self.markdown = markdown
        self.language = language
        self.translationPending = translationPending
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try c.decode(String.self, forKey: .markdown)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        translationPending = try c.decodeIfPresent(Bool.self, forKey: .translationPending) ?? false
    }
}

/// `GET /api/v1/summaries/:id/translations`: the languages a summary is already translated into.
public struct SummaryTranslations: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public var language: String
        /// The source text is translated too.
        public var sourceTranslated: Bool
        /// The translated source text is still being written.
        public var sourcePending: Bool

        public init(language: String, sourceTranslated: Bool = false, sourcePending: Bool = false) {
            self.language = language
            self.sourceTranslated = sourceTranslated
            self.sourcePending = sourcePending
        }
    }

    public var originalLanguage: String
    public var items: [Item]

    public init(originalLanguage: String, items: [Item]) {
        self.originalLanguage = originalLanguage
        self.items = items
    }

    /// Whether `language` already has a translation (so switching to it is instant and free).
    public func contains(_ language: SummaryLanguage) -> Bool {
        items.contains { SummaryLanguage(languageTag: $0.language) == language }
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
