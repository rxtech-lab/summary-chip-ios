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
    /// Uploads a todo attachment directly to storage and returns its lasting URL.
    public func uploadDocumentFile(data: Data, filename: String, mimeType: String,
                                   progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> TodoAttachment {
        guard data.count <= Self.documentFileMaxBytes else { throw SummaryAPIError.fileTooLarge(maxBytes: Self.documentFileMaxBytes) }
        let metadata = CreateUploadRequest(filename: filename, mimeType: mimeType, byteSize: data.count)
        let ticket: UploadTicket = try await send(json("/api/v1/document-files/uploads", method: "POST", body: metadata))
        try await uploadDocumentData(data, ticket: ticket, progress: progress)
        struct Body: Encodable { let uploadKey: String }
        struct Result: Decodable { let file: TodoAttachment }
        let result: Result = try await send(json("/api/v1/document-files", method: "POST", body: Body(uploadKey: ticket.key)))
        return result.file
    }
    public static let documentFileMaxBytes = 25 * 1024 * 1024
    /// Reusable by every Markdown editor. Direct signed S3 PUT followed by WebP finalization.
    public func uploadDocumentImage(data: Data, filename: String, mimeType: String,
                                    progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard data.count <= 15 * 1024 * 1024 else { throw SummaryAPIError.fileTooLarge(maxBytes: 15 * 1024 * 1024) }
        let ticket = try await createUpload(CreateUploadRequest(filename: filename, mimeType: mimeType, byteSize: data.count))
        try await uploadDocumentData(data, ticket: ticket, progress: progress)
        struct Body: Encodable { let uploadKey: String }
        struct Image: Decodable { let url: URL }
        struct Result: Decodable { let image: Image }
        let result: Result = try await send(json("/api/v1/document-images", method: "POST", body: Body(uploadKey: ticket.key)))
        return result.image.url
    }

    func uploadDocumentData(_ data: Data, ticket: UploadTicket,
                                    progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var request = URLRequest(url: ticket.uploadUrl)
        request.httpMethod = "PUT"
        request.timeoutInterval = Self.createTimeout
        for (name, value) in ticket.headers { request.setValue(value, forHTTPHeaderField: name) }
        try await DirectImageUpload.upload(data, request: request, session: session, progress: progress)
    }
}
