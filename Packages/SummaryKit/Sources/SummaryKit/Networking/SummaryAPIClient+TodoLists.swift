import Foundation
import RichDocumentEditor

extension SummaryAPIClient {
    private struct TodoEnvelope: Decodable { let todoList: TodoList }
    public func todoList(id: String) async throws -> TodoList {
        let result: TodoEnvelope = try await send(get("/api/v1/todo-lists/\(id.urlPathEscaped)"))
        return result.todoList
    }
    public func createTodoList(_ document: TodoDocument, visibility: SummaryVisibility = .private) async throws -> TodoList {
        struct Body: Encodable { let document: TodoDocument; let visibility: SummaryVisibility }
        let result: TodoEnvelope = try await send(json("/api/v1/todo-lists", method: "POST", body: Body(document: document, visibility: visibility)))
        return result.todoList
    }
    public func updateTodoList(id: String, document: TodoDocument, revision: Int) async throws -> TodoList {
        struct Body: Encodable { let document: TodoDocument; let revision: Int }
        let result: TodoEnvelope = try await send(json("/api/v1/todo-lists/\(id.urlPathEscaped)", method: "PUT", body: Body(document: document, revision: revision)))
        return result.todoList
    }
    /// Reusable by every Markdown editor. Direct signed S3 PUT followed by WebP finalization.
    public func uploadDocumentImage(data: Data, filename: String, mimeType: String,
                                    progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard data.count <= 15 * 1024 * 1024 else { throw SummaryAPIError.fileTooLarge(maxBytes: 15 * 1024 * 1024) }
        let ticket = try await createUpload(CreateUploadRequest(filename: filename, mimeType: mimeType, byteSize: data.count))
        var put = URLRequest(url: ticket.uploadUrl)
        put.httpMethod = "PUT"
        put.timeoutInterval = Self.createTimeout
        for (name, value) in ticket.headers { put.setValue(value, forHTTPHeaderField: name) }
        try await DirectImageUpload.upload(data, request: put, progress: progress)
        struct Body: Encodable { let uploadKey: String }
        struct Image: Decodable { let url: URL }
        struct Result: Decodable { let image: Image }
        let result: Result = try await send(json("/api/v1/document-images", method: "POST", body: Body(uploadKey: ticket.key)))
        return result.image.url
    }
}
