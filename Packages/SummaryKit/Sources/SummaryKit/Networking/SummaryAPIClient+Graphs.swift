import Foundation

extension SummaryAPIClient {
    private struct GraphEnvelope: Decodable { var graph: Graph }

    public func graph(id: String) async throws -> Graph {
        let result: GraphEnvelope = try await send(get("/api/v1/graphs/\(id.urlPathEscaped)"))
        return result.graph
    }

    public func createGraph(_ document: GraphDocument, visibility: SummaryVisibility = .private) async throws -> Graph {
        struct Body: Encodable { let document: GraphDocument; let visibility: SummaryVisibility }
        var request = try json("/api/v1/graphs", method: "POST", body: Body(document: document, visibility: visibility))
        // The server designs the cover before answering.
        request.timeoutInterval = Self.createTimeout
        let result: GraphEnvelope = try await send(request)
        return result.graph
    }

    /// Applies changes as one edit, over the latest revision.
    public func updateGraph(id: String, operations: [GraphOperation]) async throws -> Graph {
        struct Body: Encodable { let operations: [GraphOperation] }
        let result: GraphEnvelope = try await send(json("/api/v1/graphs/\(id.urlPathEscaped)/operations", method: "POST", body: Body(operations: operations)))
        return result.graph
    }

    public func queryGraph(id: String, query: String) async throws -> GraphQueryResult {
        struct Body: Encodable { let query: String }
        struct Result: Decodable { let result: GraphQueryResult }
        let response: Result = try await send(json("/api/v1/graphs/\(id.urlPathEscaped)/query", method: "POST", body: Body(query: query)))
        return response.result
    }

    /// Keeps what the view picks out; nil clears it.
    public func setGraphSelection(id: String, selection: GraphSelection?) async throws {
        struct Body: Encodable {
            let selection: GraphSelection?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(selection, forKey: .selection)
            }
            enum CodingKeys: String, CodingKey { case selection }
        }
        _ = try await sendRaw(json("/api/v1/graphs/\(id.urlPathEscaped)/selection", method: "PUT", body: Body(selection: selection)))
    }

    /// Uploads an image straight to the presigned URL, then stores it for the graph and returns its
    /// lasting URL. The bytes never go through the API's 4.5 MB request limit.
    public func uploadGraphImage(id: String, data: Data, filename: String, mimeType: String) async throws -> URL {
        guard data.count <= Self.maxUploadBytes else { throw SummaryAPIError.fileTooLarge(maxBytes: Self.maxUploadBytes) }
        let ticket = try await createUpload(CreateUploadRequest(filename: filename, mimeType: mimeType, byteSize: data.count))
        var put = URLRequest(url: ticket.uploadUrl)
        put.httpMethod = "PUT"
        put.timeoutInterval = Self.createTimeout
        for (name, value) in ticket.headers { put.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await session.upload(for: put, from: data)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SummaryAPIError.uploadFailed(status: http.statusCode) }
        struct Body: Encodable { let uploadKey: String }
        struct Stored: Decodable { let url: URL }
        struct Result: Decodable { let image: Stored }
        let result: Result = try await send(json("/api/v1/graphs/\(id.urlPathEscaped)/images", method: "POST", body: Body(uploadKey: ticket.key)))
        return result.image.url
    }
}
