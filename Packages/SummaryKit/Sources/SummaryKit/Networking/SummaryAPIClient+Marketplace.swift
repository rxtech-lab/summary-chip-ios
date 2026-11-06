import Foundation

public struct MarketplaceItem: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let kind: String
    public let slug: String
    public let authorId: String
    public let authorName: String?
    public let publishedAt: Date
    /// The whole summary, for drawing it as a regular feed card.
    public let chip: Summary
}
public struct MarketplacePage: Decodable, Sendable {
    public let items: [MarketplaceItem]
    public let nextOffset: Int?
}
extension SummaryAPIClient {
    /// `mine` lists what the signed-in user published, including chips Discover currently hides.
    public func marketplace(author: String? = nil, mine: Bool = false, offset: Int = 0) async throws -> MarketplacePage {
        var query = [URLQueryItem(name: "offset", value: String(offset))]
        if let author { query.append(URLQueryItem(name: "author", value: author)) }
        if mine { query.append(URLQueryItem(name: "scope", value: "mine")) }
        return try await send(get("/api/v1/marketplace", query: query))
    }
    public func publishToMarketplace(summaryID: String?, podcastKey: String? = nil, published: Bool) async throws {
        struct Body: Encodable { let summaryId: String?; let podcastKey: String? }
        _ = try await sendRaw(json("/api/v1/marketplace", method: published ? "POST" : "DELETE", body: Body(summaryId: summaryID, podcastKey: podcastKey)))
    }
    public func followedAuthors() async throws -> Set<String> {
        struct Author: Decodable { let authorId: String }
        struct Result: Decodable { let items: [Author] }
        let result: Result = try await send(get("/api/v1/authors/follow"))
        return Set(result.items.map(\.authorId))
    }
    public func followAuthor(_ authorID: String, following: Bool) async throws {
        struct Body: Encodable { let authorId: String }
        _ = try await sendRaw(json("/api/v1/authors/follow", method: following ? "POST" : "DELETE", body: Body(authorId: authorID)))
        await MainActor.run { NotificationCenter.default.post(name: .authorFollowingChanged, object: nil) }
    }
}

public extension Notification.Name {
    static let authorFollowingChanged = Notification.Name("authorFollowingChanged")
}
