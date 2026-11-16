import Foundation
import Testing
@testable import SummaryKit

struct TodoListTests {
    @Test func decodesOffsetDeadlinesAndCompletion() throws {
        let data = Data(#"{"id":"todo","revision":2,"isOwner":true,"visibility":"private","shareUrl":"https://example.com/s/todo","updatedAt":"2026-11-16T00:00:00Z","document":{"title":"Today","description":"**Notes** ![Photo](https://example.com/photo.webp)","deadline":"2026-11-16T12:00:00+08:00","items":[{"id":"one","title":"Work","deadline":"2026-11-16T11:00:00+08:00","completed":false}]}}"#.utf8)
        let list = try SummaryJSON.decoder().decode(TodoList.self, from: data)
        #expect(list.document.deadline == ISO8601DateFormatter().date(from: "2026-11-16T04:00:00Z"))
        #expect(!list.document.isCompleted)
        var completed = list.document
        completed.items[0].completed = true
        #expect(completed.isCompleted)
        let roundTrip = try SummaryJSON.decoder().decode(TodoDocument.self, from: SummaryJSON.encoder().encode(completed))
        #expect(roundTrip == completed)
        #expect(roundTrip.description.contains("photo.webp"))
    }
    @Test func libraryRecognizesTodoLists() {
        #expect(SummaryKind(rawValue: "todo_list") == .todoList)
        #expect(SummaryKind.todoList.rawValue == "todo_list")
        #expect(SummaryKind.known.contains(.todoList))
        #expect(SummaryKind.todoList.systemImage == "checklist")
    }
}
