import Foundation

/// A previewable image or downloadable file attached to a todo item.
public struct TodoAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var url: URL
    public var name: String
    public var contentType: String
    public var size: Int
    public init(id: String = UUID().uuidString, url: URL, name: String, contentType: String, size: Int) {
        self.id = id
        self.url = url
        self.name = name
        self.contentType = contentType
        self.size = size
    }
    public var isImage: Bool { contentType.hasPrefix("image/") }
}

public struct TodoItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var deadline: Date
    public var completed: Bool
    public var attachments: [TodoAttachment]
    public init(id: String = UUID().uuidString, title: String = "", deadline: Date = .now, completed: Bool = false,
                attachments: [TodoAttachment] = []) {
        self.id = id
        self.title = title
        self.deadline = deadline
        self.completed = completed
        self.attachments = attachments
    }
    private enum CodingKeys: String, CodingKey { case id, title, deadline, completed, attachments }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        deadline = try container.decode(Date.self, forKey: .deadline)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        // Lists saved before attachments existed omit the field.
        attachments = try container.decodeIfPresent([TodoAttachment].self, forKey: .attachments) ?? []
    }
}
public struct TodoDocument: Codable, Sendable, Hashable {
    public var title: String
    public var description: String
    public var deadline: Date
    public var items: [TodoItem]
    public init(title: String = "", description: String = "", deadline: Date = .now.addingTimeInterval(86400), items: [TodoItem] = []) {
        self.title = title; self.description = description; self.deadline = deadline; self.items = items
    }
    public var isCompleted: Bool { items.allSatisfy(\.completed) }
}
public struct TodoList: Decodable, Sendable, Identifiable {
    public var id: String
    public var revision: Int
    public var document: TodoDocument
    public var isOwner: Bool
    public var visibility: SummaryVisibility
    public var shareUrl: URL
    public var updatedAt: Date
}
