import Foundation

extension SummaryAPIClient {
    // MARK: Versions

    /// The owner's saved versions of a summary or trip (`id` is the library item's id), newest first.
    public func versions(id: String, cursor: String? = nil, limit: Int? = nil) async throws -> DocumentVersionPage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await send(get("/api/v1/summaries/\(id.urlPathEscaped)/versions", query: query))
    }

    /// One version with its content: a summary's text or a trip's document.
    public func version(id: String, number: Int) async throws -> DocumentVersionDetail {
        try await send(get("/api/v1/summaries/\(id.urlPathEscaped)/versions/\(number)"))
    }

    /// Saves the version's content as the item's newest version (so it can be undone the same way).
    public func restoreVersion(id: String, number: Int) async throws -> DocumentVersionRestore {
        var request = self.request("/api/v1/summaries/\(id.urlPathEscaped)/versions/\(number)/restore")
        request.httpMethod = "POST"
        return try await send(request)
    }
}
