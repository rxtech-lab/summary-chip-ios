import Foundation

/// `GET|POST|DELETE /api/v1/account/deletion`. Pending iff `deletionScheduledAt` is set.
public struct AccountDeletionState: Codable, Sendable, Hashable {
    public var pendingDeletion: Bool
    public var deletionScheduledAt: Date?
    public var deletionRequestedAt: Date?

    public init(pendingDeletion: Bool, deletionScheduledAt: Date? = nil, deletionRequestedAt: Date? = nil) {
        self.pendingDeletion = pendingDeletion
        self.deletionScheduledAt = deletionScheduledAt
        self.deletionRequestedAt = deletionRequestedAt
    }

    public static let none = AccountDeletionState(pendingDeletion: false)
}

/// Markdown documents served unauthenticated at `/api/v1/legal/<rawValue>`.
public enum LegalDocument: String, Sendable, Hashable, CaseIterable {
    case privacy
    case terms

    public var title: String {
        switch self {
        case .privacy: String(localized: "Privacy Policy", bundle: .module)
        case .terms: String(localized: "Terms of Service", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .privacy: "hand.raised"
        case .terms: "doc.text"
        }
    }

    public func url(relativeTo baseURL: URL) -> URL {
        baseURL.appending(path: "/api/v1/legal/\(rawValue)")
    }

    public func load(baseURL: URL, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: url(relativeTo: baseURL))
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        try SummaryAPIClient.validate(data: data, response: http)
        guard let markdown = String(data: data, encoding: .utf8), !markdown.isEmpty else {
            throw SummaryAPIError.invalidResponse
        }
        return markdown
    }
}

/// A personal key for the hosted MCP server (`GET /api/v1/api-keys`). Only its hash is stored on the
/// server, so the key itself is returned once, by `createAPIKey(name:)`.
public struct APIKey: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The key's first and last characters, e.g. `chippy_Ab3x…9fQz`.
    public var hint: String
    public var toolCallCount: Int
    public var summariesAddedCount: Int
    public var lastUsedAt: Date?
    public var createdAt: Date

    public init(id: String, name: String, hint: String, toolCallCount: Int = 0, summariesAddedCount: Int = 0, lastUsedAt: Date? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.hint = hint
        self.toolCallCount = toolCallCount
        self.summariesAddedCount = summariesAddedCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}

/// `POST /api/v1/api-keys`: the new key in full, the only time it can be read.
public struct CreatedAPIKey: Codable, Sendable, Hashable {
    public var key: String
    public var apiKey: APIKey

    public init(key: String, apiKey: APIKey) {
        self.key = key
        self.apiKey = apiKey
    }
}
