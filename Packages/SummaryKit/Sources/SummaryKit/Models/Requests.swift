import Foundation

/// Output language for a generated summary (`language` in the create body).
public enum SummaryLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case es
    case fr
    case de

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Same as source"
        case .en: "English"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .ja: "日本語"
        case .ko: "한국어"
        case .es: "Español"
        case .fr: "Français"
        case .de: "Deutsch"
        }
    }
}

/// How long a shared link stays alive. `never` maps to `ttlDays: null`.
public enum TTLOption: Hashable, Sendable, Identifiable, CaseIterable {
    case days(Int)
    case never

    public static let allowedDays = [1, 3, 7, 30, 90, 365]
    public static let allCases: [TTLOption] = allowedDays.map(TTLOption.days) + [.never]
    public static let `default`: TTLOption = .days(7)

    public var id: String {
        switch self {
        case .days(let d): "\(d)"
        case .never: "never"
        }
    }

    public init(ttlDays: Int?) {
        if let ttlDays { self = .days(ttlDays) } else { self = .never }
    }

    /// Value sent to the server: a number, or `nil` meaning "never expire".
    public var ttlDays: Int? {
        switch self {
        case .days(let d): d
        case .never: nil
        }
    }

    public var title: String { TTLFormatter.optionTitle(self) }
}

public struct WebpageSource: Codable, Sendable, Hashable {
    public static let maxContentLength = 60_000
    /// The contract's cap on `html`; longer markup is dropped rather than cut mid-tag.
    public static let maxHTMLLength = 400_000

    public var url: URL
    public var title: String?
    public var content: String
    /// The main content's markup, so the server keeps the page's links, images and structure.
    public var html: String?
    public var siteName: String?
    public var lang: String?

    public init(url: URL, title: String?, content: String, html: String? = nil, siteName: String?, lang: String?) {
        self.url = url
        self.title = title
        self.content = String(content.prefix(Self.maxContentLength))
        self.html = html.flatMap { $0.isEmpty || $0.count > Self.maxHTMLLength ? nil : $0 }
        self.siteName = siteName
        self.lang = lang
    }
}

/// The `source` union from the contract's create body.
public enum SummarySource: Sendable, Hashable {
    case url(URL)
    case webpage(WebpageSource)
    case pdf(uploadKey: String, filename: String, sourceUrl: URL?)
    case text(String, title: String?)
    case local(LocalFileSource)

    public var type: SummarySourceType {
        switch self {
        case .url: .url
        case .webpage: .webpage
        case .pdf: .pdf
        case .text: .text
        case .local: .local
        }
    }
}

extension SummarySource: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, url, title, content, html, siteName, lang, uploadKey, filename, sourceUrl, text, kind
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type.rawValue, forKey: .type)
        switch self {
        case .url(let url):
            try c.encode(url.absoluteString, forKey: .url)
        case .webpage(let page):
            try c.encode(page.url.absoluteString, forKey: .url)
            try c.encodeIfPresent(page.title, forKey: .title)
            try c.encode(String(page.content.prefix(WebpageSource.maxContentLength)), forKey: .content)
            try c.encodeIfPresent(page.html, forKey: .html)
            try c.encodeIfPresent(page.siteName, forKey: .siteName)
            try c.encodeIfPresent(page.lang, forKey: .lang)
        case .pdf(let key, let filename, let sourceUrl):
            try c.encode(key, forKey: .uploadKey)
            try c.encode(filename, forKey: .filename)
            // Explicit null, per the contract (`"sourceUrl": "https://…" | null`).
            if let sourceUrl {
                try c.encode(sourceUrl.absoluteString, forKey: .sourceUrl)
            } else {
                try c.encodeNil(forKey: .sourceUrl)
            }
        case .text(let text, let title):
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(title, forKey: .title)
        case .local(let file):
            try c.encode(file.kind, forKey: .kind)
            try c.encode(file.text, forKey: .text)
            try c.encode(file.filename, forKey: .filename)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(SummarySourceType.self, forKey: .type)
        switch type {
        case .url:
            self = .url(try c.decode(URL.self, forKey: .url))
        case .webpage:
            self = .webpage(WebpageSource(
                url: try c.decode(URL.self, forKey: .url),
                title: try c.decodeIfPresent(String.self, forKey: .title),
                content: try c.decode(String.self, forKey: .content),
                html: try c.decodeIfPresent(String.self, forKey: .html),
                siteName: try c.decodeIfPresent(String.self, forKey: .siteName),
                lang: try c.decodeIfPresent(String.self, forKey: .lang)
            ))
        case .pdf:
            self = .pdf(
                uploadKey: try c.decode(String.self, forKey: .uploadKey),
                filename: try c.decode(String.self, forKey: .filename),
                sourceUrl: try c.decodeLenientURL(forKey: .sourceUrl)
            )
        case .text:
            self = .text(try c.decode(String.self, forKey: .text), title: try c.decodeIfPresent(String.self, forKey: .title))
        case .local:
            self = .local(LocalFileSource(
                filename: try c.decode(String.self, forKey: .filename),
                kind: try c.decode(LocalFileSource.Kind.self, forKey: .kind),
                text: try c.decode(String.self, forKey: .text)
            ))
        }
    }
}

/// User-chosen generation options shared by every creation surface.
public struct GenerationOptions: Hashable, Sendable {
    public var language: SummaryLanguage
    public var imageStyle: ImageStyle
    public var ttl: TTLOption
    public var visibility: SummaryVisibility
    /// Also keep a local file's text (as Markdown) with the summary. Chosen per file, never remembered.
    public var keepsSourceText: Bool

    public init(
        language: SummaryLanguage = .auto,
        imageStyle: ImageStyle = .graphic,
        ttl: TTLOption = .default,
        visibility: SummaryVisibility = .public,
        keepsSourceText: Bool = false
    ) {
        self.language = language
        self.imageStyle = imageStyle
        self.ttl = ttl
        self.visibility = visibility
        self.keepsSourceText = keepsSourceText
    }
}

/// `POST /api/v1/summaries` body.
public struct CreateSummaryRequest: Encodable, Sendable, Hashable {
    public var source: SummarySource
    public var language: SummaryLanguage
    public var imageStyle: ImageStyle
    public var ttl: TTLOption
    public var visibility: SummaryVisibility
    /// The device can read pages the server can't; such failures come back as `SOURCE_NEEDS_DEVICE`.
    public var deviceReader: Bool
    /// `false` summarises shared text as-is instead of reading a link inside it.
    public var followLinks: Bool
    /// Keep a local file's text as Markdown; links and text are always kept by the server.
    public var keepSourceText: Bool

    public init(source: SummarySource, options: GenerationOptions = .init(), deviceReader: Bool = false, followLinks: Bool = true) {
        self.source = source
        self.language = options.language
        self.imageStyle = options.imageStyle
        self.ttl = options.ttl
        self.visibility = options.visibility
        self.deviceReader = deviceReader
        self.followLinks = followLinks
        self.keepSourceText = options.keepsSourceText
    }

    private enum CodingKeys: String, CodingKey { case source, language, imageStyle, ttlDays, visibility, deviceReader, followLinks, keepSourceText }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(language, forKey: .language)
        try c.encode(imageStyle, forKey: .imageStyle)
        // `null` means "never expire" and must be sent explicitly (omitting means server default).
        if let days = ttl.ttlDays { try c.encode(days, forKey: .ttlDays) } else { try c.encodeNil(forKey: .ttlDays) }
        try c.encode(visibility, forKey: .visibility)
        if deviceReader { try c.encode(true, forKey: .deviceReader) }
        if !followLinks { try c.encode(false, forKey: .followLinks) }
        if keepSourceText { try c.encode(true, forKey: .keepSourceText) }
    }
}

/// `PATCH /api/v1/summaries/:id` body. Only set fields are sent; `ttl = .never` sends `null`.
public struct SummaryPatch: Encodable, Sendable, Hashable {
    public var visibility: SummaryVisibility?
    public var ttl: TTLOption?
    public var title: String?
    public var tags: [String]?

    public init(visibility: SummaryVisibility? = nil, ttl: TTLOption? = nil, title: String? = nil, tags: [String]? = nil) {
        self.visibility = visibility
        self.ttl = ttl
        self.title = title
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey { case visibility, ttlDays, title, tags }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(visibility, forKey: .visibility)
        if let ttl {
            if let days = ttl.ttlDays { try c.encode(days, forKey: .ttlDays) } else { try c.encodeNil(forKey: .ttlDays) }
        }
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(tags, forKey: .tags)
    }
}

public struct RegenerateImageRequest: Encodable, Sendable {
    public var imageStyle: ImageStyle
    public init(imageStyle: ImageStyle) { self.imageStyle = imageStyle }
}

public struct RecordViewRequest: Encodable, Sendable {
    public var slug: String
    public init(slug: String) { self.slug = slug }
}

/// Query for `GET /api/v1/summaries`.
/// Which part of the library to list: everything, only your own summaries, or others' you opened.
public enum LibraryScope: String, CaseIterable, Identifiable, Sendable, Hashable {
    case all, mine, viewed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All"
        case .mine: "Created"
        case .viewed: "Viewed"
        }
    }
}

public struct SummaryListQuery: Hashable, Sendable {
    public var scope: LibraryScope
    public var q: String?
    public var category: String?
    public var tag: String?
    public var visibility: SummaryVisibility?
    public var source: SummaryOrigin?
    public var cursor: String?
    public var limit: Int?

    public init(scope: LibraryScope = .all, q: String? = nil, category: String? = nil, tag: String? = nil, visibility: SummaryVisibility? = nil, source: SummaryOrigin? = nil, cursor: String? = nil, limit: Int? = nil) {
        self.scope = scope
        self.q = q
        self.category = category
        self.tag = tag
        self.visibility = visibility
        self.source = source
        self.cursor = cursor
        self.limit = limit
    }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) {
            if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        if scope != .all { add("scope", scope.rawValue) }
        add("q", q)
        add("category", category)
        add("tag", tag)
        add("visibility", visibility?.rawValue)
        add("source", source?.rawValue)
        add("cursor", cursor)
        add("limit", limit.map(String.init))
        return items
    }
}
