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
        case .privacy: "Privacy Policy"
        case .terms: "Terms of Service"
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
