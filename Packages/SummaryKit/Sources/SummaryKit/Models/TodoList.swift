import Foundation

public struct TodoItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var deadline: Date
    public var completed: Bool
    public init(id: String = UUID().uuidString, title: String = "", deadline: Date = .now, completed: Bool = false) {
        self.id = id; self.title = title; self.deadline = deadline; self.completed = completed
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
