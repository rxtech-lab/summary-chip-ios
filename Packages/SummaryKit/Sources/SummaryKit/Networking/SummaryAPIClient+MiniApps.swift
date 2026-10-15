import Foundation

extension SummaryAPIClient {
    public func miniAppCatalog() async throws -> JSONValue { try await send(get("/api/v1/mini-apps/catalog")) }
    private struct MiniEnvelope: Decodable { var app: MiniApp }
    public func miniApp(id: String) async throws -> MiniApp {
        let result: MiniEnvelope = try await send(get("/api/v1/mini-apps/\(id.urlPathEscaped)"))
        return result.app
    }
    public func createMiniApp(_ document: MiniAppDocument) async throws -> MiniApp {
        let result: MiniEnvelope = try await send(json("/api/v1/mini-apps", method: "POST", body: document))
        return result.app
    }
    public func updateMiniApp(id: String, document: MiniAppDocument, revision: Int) async throws -> MiniApp {
        struct Body: Encodable { let document: MiniAppDocument; let revision: Int }
        let result: MiniEnvelope = try await send(json("/api/v1/mini-apps/\(id.urlPathEscaped)", method: "PUT", body: Body(document: document, revision: revision)))
        return result.app
    }
    public func miniAppAction(id: String?, document: MiniAppDocument, revision: Int, action: String, state: [String: JSONValue], input: [String: JSONValue] = [:], item: JSONValue = .null, records: [String: [JSONValue]]? = nil) async throws -> MiniAppRunResult {
        struct Action: Encodable { let action: String; let state: [String: JSONValue]; let input: [String: JSONValue]; let item: JSONValue; var revision: Int?; var key: String? }
        let action = Action(action: action, state: state, input: input, item: item, revision: id == nil ? nil : revision, key: id == nil ? nil : UUID().uuidString.lowercased())
        if let id { return try await send(json("/api/v1/mini-apps/\(id.urlPathEscaped)/actions", method: "POST", body: action)) }
        struct Preview: Encodable { let document: MiniAppDocument; let action: Action; let records: [String: [JSONValue]]? }
        return try await send(json("/api/v1/mini-apps/preview", method: "POST", body: Preview(document: document, action: action, records: records)))
    }
    /// Runs one declared script of a saved app in the server sandbox, for actions executed on the device.
    public func miniAppScript(id: String, revision: Int, script: String, input: JSONValue) async throws -> JSONValue {
        struct Body: Encodable { let revision: Int; let script: String; let input: JSONValue }
        struct Result: Decodable { let value: JSONValue? }
        let result: Result = try await send(json("/api/v1/mini-apps/\(id.urlPathEscaped)/scripts", method: "POST", body: Body(revision: revision, script: script, input: input)))
        return result.value ?? .null
    }
    public func miniAppRecords(id: String, table: String, cursor: String? = nil) async throws -> MiniAppRecordPage {
        var query = [URLQueryItem(name: "table", value: table)]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(get("/api/v1/mini-apps/\(id.urlPathEscaped)/records", query: query))
    }
    public func miniAppRequest(id: String, resource: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        let path = "/api/v1/mini-apps/\(id.urlPathEscaped)/\(resource)"
        if let body {
            var payload = body
            if resource == "records", method == "POST", case .object(var fields) = body {
                fields["key"] = fields["key"] ?? .string(UUID().uuidString.lowercased())
                payload = .object(fields)
            }
            return try await send(json(path, method: method, body: payload))
        }
        var request = get(path); request.httpMethod = method
        return try await send(request)
    }
}
