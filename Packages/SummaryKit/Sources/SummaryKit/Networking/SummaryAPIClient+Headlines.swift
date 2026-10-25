import Foundation

public struct EditorialHeadline: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: SummaryKind
    public let shareUrl: URL
    public let createdAt: Date
    public let score: Int
}

public struct EditorialHeadlines: Codable, Sendable {
    public let generatedAt: Date?
    public let pending: Bool
    public let items: [EditorialHeadline]
    public let highlighted: EditorialHeadline?
}

extension SummaryAPIClient {
    public func headlines() async throws -> EditorialHeadlines {
        try await send(get("/api/v1/summaries/headlines"))
    }
}
