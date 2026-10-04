#if os(macOS)
import Foundation
import MCP
import SummaryKit

/// The tools the Mac app's MCP server offers: add a summary, search the library, list it by filter.
/// Each call goes to `/api/v1` as the signed-in user, through the app's API client.
nonisolated struct ChippyMCPTools: Sendable {
    enum Name {
        static let addSummary = "add_summary"
        static let searchSummaries = "search_summaries"
        static let listSummaries = "list_summaries"
    }

    /// The server's categories (`CATEGORIES` in `server/lib/contracts/api.ts`).
    static let categories = [
        "Technology", "Science", "Business", "Finance", "Politics", "World", "Health", "Sports",
        "Entertainment", "Culture", "Education", "Lifestyle", "Travel", "Food", "Opinion", "Research", "Other",
    ]
    static let sources = SummaryOrigin.known.map(\.rawValue)
    static let maxSearchResults = 50
    static let maxListResults = 200

    let api: SummaryAPIClient
    /// Runs after `add_summary` saves a chip, so the open library shows it.
    let onSummaryAdded: @MainActor @Sendable () async -> Void

    static let instructions = """
    Chippy is the user's library of summary cards ("chips"). Use search_summaries to find chips by meaning \
    (natural language), list_summaries to browse the library newest first by source, category, tag or \
    visibility, and add_summary to save a summary you wrote together with its raw source text. Nothing is \
    re-summarised on add, and each added chip counts against the user's summary allowance.
    """

    // MARK: Catalog

    static let tools: [Tool] = [
        Tool(
            name: Name.addSummary,
            title: "Add Summary",
            description: """
            Save a summary to the user's Chippy library, with its key points, tags and the raw source text. \
            Nothing is re-summarised: write the title, summary and key points yourself. The server designs the \
            cover, indexes the chip for search and returns the created summary with its share link. A chip \
            already in the library (same source, title or content) is refused unless allowDuplicate is true. \
            Counts as one summary against the user's allowance.
            """,
            inputSchema: schema(
                properties: [
                    "title": prop("string", "Title of the chip, at most 200 characters."),
                    "summary": prop("string", "The summary, at most 1200 characters."),
                    "text": prop("string", "The raw source text the summary was written from, at most 200,000 characters. Kept as the chip's source document."),
                    "keyPoints": stringArray("Key points shown under the summary; at most 5, each at most 300 characters."),
                    "tags": stringArray("Tags; at most 12, lowercased by the server."),
                    "keywords": stringArray("Search keywords; at most 10."),
                    "category": enumProp(categories, "Category of the chip. Default Other."),
                    "language": prop("string", "BCP-47 code of the language the title and summary are written in, e.g. en, zh-Hant. Default en."),
                    "sourceUrl": prop("string", "http(s) URL the text came from."),
                    "sourceTitle": prop("string", "Title of the source."),
                    "siteName": prop("string", "Name of the source site."),
                    "visibility": enumProp(["public", "private"], "public: anyone with the share link can open it (default). private: only the user."),
                    "ttlDays": .object([
                        "description": .string("How long the public link stays alive: 1, 3, 7, 30, 90 or 365 days, or \"never\". Default: the server's default."),
                        "oneOf": .array([
                            .object(["type": .string("integer"), "enum": .array(TTLOption.allowedDays.map { .int($0) })]),
                            .object(["type": .string("string"), "enum": .array([.string("never")])]),
                        ]),
                    ]),
                    "allowDuplicate": prop("boolean", "Save even when the library already has this chip. Default false."),
                ],
                required: ["title", "summary", "text"]
            ),
            annotations: .init(title: "Add Summary", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: Name.searchSummaries,
            title: "Search Summaries",
            description: """
            Search the user's Chippy library with a natural-language query. Matches by meaning and keywords and \
            returns the most relevant chips first. Optionally narrow by source (web, x, facebook, youtube, github, \
            pdf, text), category, tag, visibility or scope.
            """,
            inputSchema: schema(
                properties: [
                    "query": prop("string", "What to look for, in natural language, e.g. \"articles about battery recycling\". At most 200 characters."),
                    "source": enumProp(sources, "Only chips made from this kind of source."),
                ].merging(filterProperties) { first, _ in first }.merging([
                    "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(maxSearchResults), "description": .string("Results per page, 1–\(maxSearchResults). Default 10.")]),
                    "cursor": prop("string", "nextCursor from a previous search_summaries call, for the next page."),
                ]) { first, _ in first },
                required: ["query"]
            ),
            annotations: .init(title: "Search Summaries", readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: Name.listSummaries,
            title: "List Summaries",
            description: """
            List the chips in the user's Chippy library, newest first, filtered by source, category, tag, \
            visibility and scope. Use search_summaries instead to find chips by topic. Returns up to \
            \(maxListResults) chips per call; pass nextCursor back to continue.
            """,
            inputSchema: schema(
                properties: [
                    "source": enumProp(sources, "Only chips made from this kind of source."),
                ].merging(filterProperties) { first, _ in first }.merging([
                    "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(maxListResults), "description": .string("How many chips to return, 1–\(maxListResults). Default 50.")]),
                    "cursor": prop("string", "nextCursor from a previous list_summaries call, for the next page."),
                ]) { first, _ in first }
            ),
            annotations: .init(title: "List Summaries", readOnlyHint: true, openWorldHint: false)
        ),
    ]

    private static var filterProperties: [String: Value] {
        [
            "scope": enumProp(LibraryScope.allCases.map(\.rawValue), "all: the user's own chips and others' public chips they opened (default). mine: only chips the user created. viewed: only others' chips the user opened."),
            "category": enumProp(categories, "Only chips in this category."),
            "tag": prop("string", "Only chips with this tag."),
            "visibility": enumProp(["public", "private"], "Only public or only private chips."),
        ]
    }

    private static func schema(properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
        return .object(object)
    }

    private static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func enumProp(_ values: [String], _ description: String) -> Value {
        .object(["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)])
    }

    private static func stringArray(_ description: String) -> Value {
        .object(["type": "array", "items": .object(["type": "string"]), "description": .string(description)])
    }

    // MARK: Calls

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let arguments = Arguments(arguments ?? [:])
        do {
            switch name {
            case Name.addSummary: return try await addSummary(arguments)
            case Name.searchSummaries: return try await searchSummaries(arguments)
            case Name.listSummaries: return try await listSummaries(arguments)
            default: return .failure("Unknown tool: \(name)")
            }
        } catch let error as ToolError {
            return .failure(error.message)
        } catch let error as SummaryAPIError {
            return .failure(Self.describe(error))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func addSummary(_ arguments: Arguments) async throws -> CallTool.Result {
        let request = try Self.importRequest(from: arguments)
        do {
            let summary = try await api.importSummary(request)
            await onSummaryAdded()
            let payload = SummaryPayload(summary)
            return try .success(
                ["summary": payload],
                text: "Added \"\(summary.title)\" (\(summary.visibility.rawValue)).\n\(summary.shareUrl.absoluteString)"
            )
        } catch let error as SummaryAPIError {
            guard case .server(409, let body) = error, body.code == "DUPLICATE_SUMMARY" else { throw error }
            let duplicate = try? body.details?["duplicate"]?.decode(Summary.self)
            let reason = body.details?["reason"]?.stringValue
            var message = "Not added: this chip is already in the library"
            if let duplicate { message += " as \"\(duplicate.title)\" (\(duplicate.shareUrl.absoluteString))" }
            message += "."
            if let reason, !reason.isEmpty { message += " Reason: \(reason)" }
            message += " Call add_summary again with allowDuplicate: true to save it anyway."
            return .failure(message)
        }
    }

    private func searchSummaries(_ arguments: Arguments) async throws -> CallTool.Result {
        guard let query = try arguments.string("query", maxLength: 200) else { throw ToolError.missing("query") }
        var listQuery = try Self.filters(from: arguments)
        listQuery.q = query
        listQuery.limit = try arguments.integer("limit", in: 1...Self.maxSearchResults) ?? 10
        listQuery.cursor = try arguments.string("cursor")
        let page = try await api.listSummaries(listQuery)
        return try .success(ListPayload(items: page.items.map(SummaryPayload.init), nextCursor: page.nextCursor))
    }

    private func listSummaries(_ arguments: Arguments) async throws -> CallTool.Result {
        var listQuery = try Self.filters(from: arguments)
        let limit = try arguments.integer("limit", in: 1...Self.maxListResults) ?? 50
        listQuery.cursor = try arguments.string("cursor")
        // The API pages by at most 50; follow its cursor until the limit is reached.
        var items: [Summary] = []
        var nextCursor: String?
        repeat {
            listQuery.limit = min(50, limit - items.count)
            let page = try await api.listSummaries(listQuery)
            items += page.items
            nextCursor = page.nextCursor
            listQuery.cursor = nextCursor
        } while nextCursor != nil && items.count < limit
        return try .success(ListPayload(items: items.map(SummaryPayload.init), nextCursor: nextCursor))
    }

    // MARK: Argument mapping

    static func importRequest(from arguments: Arguments) throws -> ImportSummaryRequest {
        guard let title = try arguments.string("title", maxLength: 200) else { throw ToolError.missing("title") }
        guard let summary = try arguments.string("summary", maxLength: 1200) else { throw ToolError.missing("summary") }
        guard let text = try arguments.string("text", trims: false, maxLength: 200_000) else { throw ToolError.missing("text") }
        let keyPoints = try arguments.strings("keyPoints") ?? arguments.strings("highlights") ?? []
        guard keyPoints.count <= 5 else { throw ToolError.invalid("keyPoints", "at most 5 key points, got \(keyPoints.count)") }
        let tags = try arguments.strings("tags") ?? []
        guard tags.count <= 12 else { throw ToolError.invalid("tags", "at most 12 tags, got \(tags.count)") }
        let keywords = try arguments.strings("keywords") ?? []
        guard keywords.count <= 10 else { throw ToolError.invalid("keywords", "at most 10 keywords, got \(keywords.count)") }
        var sourceURL: URL?
        if let raw = try arguments.string("sourceUrl") {
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) else {
                throw ToolError.invalid("sourceUrl", "must be an http(s) URL")
            }
            sourceURL = url
        }
        return ImportSummaryRequest(
            title: title,
            summary: summary,
            text: text,
            tags: tags,
            highlights: keyPoints,
            category: try arguments.oneOf("category", categories),
            keywords: keywords,
            language: try arguments.string("language", maxLength: 35),
            sourceUrl: sourceURL,
            sourceTitle: try arguments.string("sourceTitle", maxLength: 1000),
            siteName: try arguments.string("siteName", maxLength: 300),
            // Agent-added chips get an illustrated cover, never the SVG "graphic" style.
            imageStyle: .illustration,
            ttl: try arguments.ttl("ttlDays"),
            visibility: try arguments.oneOf("visibility", ["public", "private"]).flatMap(SummaryVisibility.init(rawValue:)),
            allowDuplicate: try arguments.bool("allowDuplicate") ?? false
        )
    }

    static func filters(from arguments: Arguments) throws -> SummaryListQuery {
        SummaryListQuery(
            scope: try arguments.oneOf("scope", LibraryScope.allCases.map(\.rawValue)).flatMap(LibraryScope.init(rawValue:)) ?? .all,
            category: try arguments.oneOf("category", categories),
            tag: try arguments.string("tag", maxLength: 40),
            visibility: try arguments.oneOf("visibility", ["public", "private"]).flatMap(SummaryVisibility.init(rawValue:)),
            source: try arguments.oneOf("source", sources).map(SummaryOrigin.init(rawValue:))
        )
    }

    static func describe(_ error: SummaryAPIError) -> String {
        switch error {
        case .notSignedIn:
            "Chippy is not signed in. Open the Chippy app on this Mac and sign in, then try again."
        case .server(let status, let body) where status == 400 || status == 422:
            "The server rejected the request (\(body.code)): \(body.message)"
        default:
            error.localizedDescription
        }
    }
}

// MARK: - Arguments

nonisolated struct ToolError: Error {
    let message: String
    static func missing(_ name: String) -> ToolError { ToolError(message: "Missing required argument: \(name)") }
    static func invalid(_ name: String, _ reason: String) -> ToolError { ToolError(message: "Invalid \(name): \(reason)") }
}

/// Typed, validating reads of a tool call's arguments. Blank strings count as absent.
nonisolated struct Arguments: Sendable {
    let values: [String: Value]

    init(_ values: [String: Value]) { self.values = values }

    func string(_ name: String, trims: Bool = true, maxLength: Int? = nil) throws -> String? {
        guard let value = values[name], !value.isNull else { return nil }
        guard let raw = value.stringValue else { throw ToolError.invalid(name, "must be a string") }
        let string = trims ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let maxLength, string.count > maxLength {
            throw ToolError.invalid(name, "at most \(maxLength) characters, got \(string.count)")
        }
        return string
    }

    /// An array of strings; a single comma-separated string is accepted too.
    func strings(_ name: String) throws -> [String]? {
        guard let value = values[name], !value.isNull else { return nil }
        let parts: [String]
        if let array = value.arrayValue {
            parts = try array.map { element in
                guard let string = element.stringValue else { throw ToolError.invalid(name, "must be an array of strings") }
                return string
            }
        } else if let string = value.stringValue {
            parts = string.split(separator: ",").map(String.init)
        } else {
            throw ToolError.invalid(name, "must be an array of strings")
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func integer(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = values[name], !value.isNull else { return nil }
        let number: Int? = switch value {
        case .int(let int): int
        case .double(let double): Int(exactly: double)
        case .string(let string): Int(string.trimmingCharacters(in: .whitespaces))
        default: nil
        }
        guard let number else { throw ToolError.invalid(name, "must be an integer") }
        guard range.contains(number) else { throw ToolError.invalid(name, "must be between \(range.lowerBound) and \(range.upperBound)") }
        return number
    }

    func bool(_ name: String) throws -> Bool? {
        guard let value = values[name], !value.isNull else { return nil }
        if let bool = value.boolValue { return bool }
        switch value.stringValue?.lowercased() {
        case "true": return true
        case "false": return false
        default: throw ToolError.invalid(name, "must be true or false")
        }
    }

    func oneOf(_ name: String, _ allowed: [String]) throws -> String? {
        guard let string = try string(name) else { return nil }
        // Accept any casing, send the canonical value.
        guard let match = allowed.first(where: { $0.caseInsensitiveCompare(string) == .orderedSame }) else {
            throw ToolError.invalid(name, "must be one of \(allowed.joined(separator: ", "))")
        }
        return match
    }

    func ttl(_ name: String) throws -> TTLOption? {
        guard let value = values[name], !value.isNull else { return nil }
        if value.stringValue?.lowercased() == "never" { return .never }
        let days = try integer(name, in: 1...365)
        guard let days, TTLOption.allowedDays.contains(days) else {
            throw ToolError.invalid(name, "must be 1, 3, 7, 30, 90, 365 or \"never\"")
        }
        return .days(days)
    }
}

// MARK: - Results

/// What the tools return for a chip: everything an agent needs to cite or open it, no artwork URLs.
nonisolated struct SummaryPayload: Encodable, Sendable {
    let id: String
    let title: String
    let summary: String
    let keyPoints: [String]
    let category: String
    let tags: [String]
    let source: String
    let sourceUrl: URL?
    let sourceTitle: String?
    let siteName: String?
    let shareUrl: URL
    let visibility: String
    let language: String
    let isOwner: Bool
    let hasSourceText: Bool
    let createdAt: Date
    let viewedAt: Date?

    init(_ summary: Summary) {
        id = summary.id
        title = summary.title
        self.summary = summary.summary
        keyPoints = summary.highlights
        category = summary.category
        tags = summary.tags
        source = summary.source.rawValue
        sourceUrl = summary.sourceUrl
        sourceTitle = summary.sourceTitle
        siteName = summary.siteName
        shareUrl = summary.shareUrl
        visibility = summary.visibility.rawValue
        language = summary.language
        isOwner = summary.isOwner
        hasSourceText = summary.hasSourceMarkdown
        createdAt = summary.createdAt
        viewedAt = summary.viewedAt
    }
}

nonisolated struct ListPayload: Encodable, Sendable {
    let items: [SummaryPayload]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey { case count, items, nextCursor }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items.count, forKey: .count)
        try c.encode(items, forKey: .items)
        // Explicit null tells the agent there is nothing more to fetch.
        if let nextCursor { try c.encode(nextCursor, forKey: .nextCursor) } else { try c.encodeNil(forKey: .nextCursor) }
    }
}

nonisolated extension CallTool.Result {
    /// Structured content plus the same JSON as text, for clients that only read text blocks.
    static func success(_ payload: some Encodable, text: String? = nil) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        // Typed as `Value?` to pick the non-throwing init over the generic `Codable` overload.
        let structured: Value? = try JSONDecoder().decode(Value.self, from: data)
        var content: [Tool.Content] = []
        if let text { content.append(.text(text: text, annotations: nil, _meta: nil)) }
        content.append(.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil))
        return CallTool.Result(content: content, structuredContent: structured, isError: false)
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
#endif
