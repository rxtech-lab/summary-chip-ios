import Foundation

extension SummaryAPIClient {
    private struct RichDocumentEnvelope: Decodable { var richDocument: RichDocument }

    public func richDocument(id: String) async throws -> RichDocument {
        let result: RichDocumentEnvelope = try await send(get("/api/v1/rich-documents/\(id.urlPathEscaped)"))
        return result.richDocument
    }

    /// Creates a document from Markdown. With no `title`, the first line's `# heading` becomes the title.
    public func createRichDocument(markdown: String, title: String? = nil, visibility: SummaryVisibility = .private) async throws -> RichDocument {
        struct Body: Encodable { let markdown: String; let title: String?; let visibility: SummaryVisibility }
        var request = try json("/api/v1/rich-documents", method: "POST", body: Body(markdown: markdown, title: title, visibility: visibility))
        // The server designs the cover before answering.
        request.timeoutInterval = Self.createTimeout
        let result: RichDocumentEnvelope = try await send(request)
        return result.richDocument
    }

    /// The document as Markdown (`?format=markdown`), for sharing or copying.
    public func richDocumentMarkdown(id: String) async throws -> String {
        let data = try await sendRaw(get("/api/v1/rich-documents/\(id.urlPathEscaped)", query: [URLQueryItem(name: "format", value: "markdown")]))
        return String(decoding: data, as: UTF8.self)
    }
}
