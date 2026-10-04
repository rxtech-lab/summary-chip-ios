#if os(macOS)
import Foundation
import SummaryKit
import Testing
@testable import summary_chip

/// Drives the Mac app's MCP server over real HTTP on the loopback interface, with `/api/v1` stubbed.
@MainActor
@Suite(.serialized) struct MCPServerTests {
    private static let token = "chippy_test-token"

    @Test func rejectsRequestsWithoutTheAccessToken() async throws {
        try await withServer { client in
            let (status, _) = try await client.post(Self.initialize, token: nil)
            #expect(status == 401)
            let (wrongStatus, _) = try await client.post(Self.initialize, token: "chippy_wrong")
            #expect(wrongStatus == 401)
        }
    }

    @Test func listsTheThreeTools() async throws {
        try await withServer { client in
            try await client.initialize()
            let response = try await client.rpc("tools/list")
            let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            #expect(Set(tools.compactMap { $0["name"] as? String }) == ["add_summary", "search_summaries", "list_summaries"])
            let add = try #require(tools.first { $0["name"] as? String == "add_summary" })
            let required = (add["inputSchema"] as? [String: Any])?["required"] as? [String]
            #expect(required == ["title", "summary", "text"])
        }
    }

    @Test func searchSendsTheQueryAndSourceFilter() async throws {
        try await withServer { client in
            try await client.initialize()
            let response = try await client.callTool("search_summaries", ["query": "battery recycling", "source": "youtube", "limit": 5])
            let result = try #require(response["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == false)
            let structured = try #require(result["structuredContent"] as? [String: Any])
            let items = try #require(structured["items"] as? [[String: Any]])
            #expect(items.first?["title"] as? String == "Chip 1")
            #expect(items.first?["keyPoints"] as? [String] == ["One", "Two"])

            let request = try #require(MCPBackend.requests.values.last)
            let query = Self.query(of: request)
            #expect(query["q"] == "battery recycling")
            #expect(query["source"] == "youtube")
            #expect(query["limit"] == "5")
        }
    }

    @Test func listFollowsCursorsUpToTheLimit() async throws {
        try await withServer { client in
            try await client.initialize()
            let response = try await client.callTool("list_summaries", ["category": "technology", "scope": "mine", "limit": 80])
            let structured = try #require((response["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
            #expect(structured["count"] as? Int == 80)
            #expect(structured["nextCursor"] as? String == "page-3")

            let queries = MCPBackend.requests.values.filter { $0.httpMethod == "GET" }.map(Self.query)
            #expect(queries.count == 2)
            #expect(queries[0]["category"] == "Technology")
            #expect(queries[0]["scope"] == "mine")
            #expect(queries[0]["q"] == nil)
            #expect(queries[0]["limit"] == "50")
            #expect(queries[1]["cursor"] == "page-2")
            #expect(queries[1]["limit"] == "30")
        }
    }

    @Test func addImportsTheSummaryAndRefreshesTheLibrary() async throws {
        let added = AddedCounter()
        try await withServer(onSummaryAdded: { added.count += 1 }) { client in
            try await client.initialize()
            let response = try await client.callTool("add_summary", [
                "title": "Monarch migration",
                "summary": "Monarchs fly south each autumn.",
                "text": "Raw notes…",
                "keyPoints": ["They travel up to 4,000 km"],
                "tags": "butterflies, migration",
                "ttlDays": "never",
                "visibility": "private",
            ])
            let result = try #require(response["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == false)

            let request = try #require(MCPBackend.requests.values.last)
            #expect(request.url?.path == "/api/v1/summaries/import")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer backend-token")
            let body = try #require(MCPBackend.body(of: request))
            #expect(body["title"] as? String == "Monarch migration")
            #expect(body["highlights"] as? [String] == ["They travel up to 4,000 km"])
            #expect(body["tags"] as? [String] == ["butterflies", "migration"])
            #expect(body["imageStyle"] as? String == "illustration")
            #expect(body["visibility"] as? String == "private")
            #expect(body.keys.contains("ttlDays") && body["ttlDays"] is NSNull)
        }
        #expect(added.count == 1)
    }

    @Test func duplicateAndInvalidAddsComeBackAsToolErrors() async throws {
        try await withServer { client in
            try await client.initialize()
            let duplicate = try await client.callTool("add_summary", ["title": "Duplicate", "summary": "S", "text": "T"])
            #expect((duplicate["result"] as? [String: Any])?["isError"] as? Bool == true)
            #expect(Self.text(of: duplicate).contains("allowDuplicate"))
            #expect(Self.text(of: duplicate).contains("Chip 9"))

            let missing = try await client.callTool("add_summary", ["title": "No text", "summary": "S"])
            #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)
            #expect(Self.text(of: missing).contains("text"))

            let badCategory = try await client.callTool("search_summaries", ["query": "x", "category": "Gardening"])
            #expect(Self.text(of: badCategory).contains("category"))
        }
    }

    // MARK: Helpers

    private static let initialize: [String: Any] = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any], "clientInfo": ["name": "tests", "version": "1"]],
    ]

    private func withServer(
        onSummaryAdded: @escaping @MainActor @Sendable () -> Void = {},
        _ body: (MCPTestClient) async throws -> Void
    ) async throws {
        MCPBackend.requests.clear()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPBackend.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://mcp-backend.test")!, tokenProvider: MCPBackendToken(),
                                   session: URLSession(configuration: configuration))
        let tools = ChippyMCPTools(api: api) { onSummaryAdded() }
        let server = MCPHTTPServer(token: Self.token, tools: tools, version: "test")
        var port = 0
        for _ in 0..<10 {
            let candidate = Int.random(in: 49_152...64_000)
            do {
                try await server.start(port: candidate)
                port = candidate
                break
            } catch MCPServerError.portInUse {
                continue
            }
        }
        try #require(port != 0)
        do {
            try await body(MCPTestClient(port: port, token: Self.token))
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private static func query(of request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    private static func text(of response: [String: Any]) -> String {
        let content = (response["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

@MainActor private final class AddedCounter {
    var count = 0
}

/// A minimal Streamable HTTP MCP client.
private final class MCPTestClient {
    let endpoint: URL
    let token: String
    private var sessionID: String?
    private var nextID = 2
    private let session = URLSession(configuration: .ephemeral)

    init(port: Int, token: String) {
        endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        self.token = token
    }

    func initialize() async throws {
        let (status, response) = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any], "clientInfo": ["name": "tests", "version": "1"]],
        ], token: token)
        try #require(status == 200)
        try #require(response?["result"] != nil)
        _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token)
    }

    func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let (status, response) = try await post(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params], token: token)
        try #require(status == 200)
        return try #require(response)
    }

    func callTool(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        try await rpc("tools/call", ["name": name, "arguments": arguments])
    }

    /// Returns the status and the JSON-RPC message from a JSON or SSE body.
    func post(_ message: [String: Any], token: String?) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        if let id = http.value(forHTTPHeaderField: "MCP-Session-Id") { sessionID = id }
        let text = String(decoding: data, as: UTF8.self)
        // SSE: skip the empty priming event and take the message's `data:` line.
        let json = text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("data:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? text
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return (http.statusCode, object)
    }
}

nonisolated private struct MCPBackendToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "backend-token" }
}

nonisolated private final class MCPRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
    func clear() { lock.withLock { storage.removeAll() } }
}

/// Stubs `/api/v1`: paged lists of 50, an import, and a duplicate refusal for the title "Duplicate".
nonisolated private final class MCPBackend: URLProtocol, @unchecked Sendable {
    static let requests = MCPRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp-backend.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override func startLoading() {
        var recorded = request
        if let body = Self.body(of: request) { recorded.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        Self.requests.append(recorded)

        let status: Int
        let json: String
        if request.url?.path == "/api/v1/summaries/import" {
            if Self.body(of: recorded)?["title"] as? String == "Duplicate" {
                status = 409
                json = #"{"error":{"code":"DUPLICATE_SUMMARY","message":"Already saved.","details":{"reason":"Same source URL.","duplicate":\#(Self.summary(9))}}}"#
            } else {
                status = 201
                json = Self.summary(1)
            }
        } else {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let limit = items.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? 20
            let page = items.first { $0.name == "cursor" }?.value == "page-2" ? 2 : 1
            status = 200
            json = #"{"items":[\#((1...limit).map { Self.summary((page - 1) * 50 + $0) }.joined(separator: ","))],"nextCursor":"page-\#(page + 1)"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func summary(_ number: Int) -> String {
        """
        {"id":"id-\(number)","slug":"slug\(number)","shareUrl":"https://summary.rxlab.app/s/slug\(number)","ogImageUrl":null,\
        "sourceType":"url","source":"web","sourceUrl":"https://example.com/\(number)","sourceTitle":null,"siteName":null,\
        "sourceFileUrl":null,"title":"Chip \(number)","summary":"Summary \(number).","highlights":["One","Two"],\
        "category":"Technology","tags":["ai"],"keywords":[],"language":"en",\
        "theme":{"colors":["#104b8f","#18673c","#efcabc"],"mode":"dark","emoji":"📰","accent":"#104b8f"},\
        "imageStyle":"illustration","visibility":"public","ttlDays":7,"expiresAt":null,"viewCount":0,"isOwner":true,\
        "createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-01T00:00:00.000Z"}
        """
    }
}
#endif
