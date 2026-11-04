#if DEBUG
import Foundation
import SummaryKit
import SwiftUI

/// `--preview-graph`: the real graph screen against an in-memory API, for UI tests and reviewing it
/// without a server. Edits stay in memory; the query endpoint answers a few canned queries.
struct GraphPreviewHost: View {
    @State private var environment = GraphPreviewAPI.environment()

    var body: some View {
        NavigationStack {
            GraphDetailView(environment: environment, graphID: GraphPreviewAPI.graphID, title: "Computing Pioneers")
        }
    }
}

nonisolated final class GraphPreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = GraphPreviewStore.shared.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

enum GraphPreviewAPI {
    nonisolated static let graphID = "preview-graph"

    static func environment() -> AppEnvironment {
        let token = SharedTokenBundle(accessToken: "preview-token", refreshToken: nil, idToken: nil, expiresAt: .now.addingTimeInterval(86_400), subject: "preview-user")
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [GraphPreviewProtocol.self]
        let environment = AppEnvironment.live(configuration: .live(), vault: InMemoryTokenVault(token), session: URLSession(configuration: session), authenticationState: .signedIn)
        environment.chatStore.remove(key: "graph:\(graphID)")
        return environment
    }
}

nonisolated final class GraphPreviewStore: @unchecked Sendable {
    static let shared = GraphPreviewStore()
    private let lock = NSLock()
    private var graph = GraphPreviewStore.initial()

    private static func initial() -> [String: Any] { [
        "id": GraphPreviewAPI.graphID, "slug": "preview", "revision": 0, "visibility": "private", "isOwner": true,
        "createdAt": "2026-11-04T00:00:00.000Z", "updatedAt": "2026-11-04T00:00:00.000Z", "shareUrl": "https://example.com/s/preview", "selection": NSNull(),
        "document": [
            "version": 1, "title": "Computing Pioneers", "description": "Who built what.",
            "nodes": [
                ["id": "ada", "label": "Ada Lovelace", "types": ["Person"], "properties": ["born": 1815, "field": "mathematics", "address": ["city": "London"]], "images": [],
                 "view": ["root": "root", "elements": ["root": ["type": "Callout", "props": ["title": "First programmer", "text": "Wrote the first published algorithm.", "tone": "tip"]]]]],
                ["id": "babbage", "label": "Charles Babbage", "types": ["Person"], "properties": ["born": 1791], "images": []],
                ["id": "engine", "label": "Analytical Engine", "types": ["Machine"], "properties": ["year": 1837], "images": []],
                ["id": "turing", "label": "Alan Turing", "types": ["Person"], "properties": ["born": 1912], "images": []],
                ["id": "enigma", "label": "Bombe", "types": ["Machine"], "properties": ["year": 1939], "images": []],
            ] as [[String: Any]],
            "edges": [
                ["id": "worked", "source": "ada", "target": "babbage", "label": "WORKED_WITH", "directed": false, "properties": ["since": 1833], "images": []],
                ["id": "designed", "source": "babbage", "target": "engine", "label": "DESIGNED", "directed": true, "properties": [:], "images": []],
                ["id": "programmed", "source": "ada", "target": "engine", "label": "PROGRAMMED", "directed": true, "properties": [:], "images": []],
                ["id": "built", "source": "turing", "target": "enigma", "label": "BUILT", "directed": true, "properties": [:], "images": []],
            ] as [[String: Any]],
            "queries": [["id": "machines", "name": "Machines", "query": "MATCH (m:Machine) RETURN m"]],
        ] as [String: Any],
    ] }

    private static let chatEvents = """
    {"type":"start"}
    {"type":"tool-input-available","toolCallId":"call-select","toolName":"selectGraphElements","input":{"mode":"isolate","query":"MATCH (n:Person) RETURN n"}}
    {"type":"tool-output-available","toolCallId":"call-select","output":{"graphSelection":{"mode":"isolate","nodeIds":["ada","babbage","turing"],"edgeIds":[],"query":"MATCH (n:Person) RETURN n"},"nodeCount":3,"edgeCount":0}}
    {"type":"text-start","id":"t"}
    {"type":"text-delta","id":"t","delta":"I'm showing only the people."}
    {"type":"text-end","id":"t"}
    {"type":"finish"}
    """

    func respond(to request: URLRequest) -> (Int, Data) {
        lock.withLock { route(request) }
    }

    private func route(_ request: URLRequest) -> (Int, Data) {
        let path = request.url?.pathComponents.filter { $0 != "/" } ?? []
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        if path.suffix(1) == ["chat"] {
            // The real selection tool persists its result before returning it to the chat.
            graph["selection"] = [
                "mode": "isolate", "nodeIds": ["ada", "babbage", "turing"],
                "edgeIds": [String](), "query": "MATCH (n:Person) RETURN n",
            ] as [String: Any]
            let lines = Self.chatEvents.split(separator: "\n").map { "data: \($0.trimmingCharacters(in: .whitespaces))\n\n" }.joined() + "data: [DONE]\n\n"
            return (200, Data(lines.utf8))
        }
        if path.contains("versions") { return json(["items": [], "nextCursor": NSNull()]) }
        switch (method, path.last) {
        case ("POST", "query"): return query(body)
        case ("POST", "operations"):
            apply(body)
            return json(["graph": graph])
        case ("PUT", "selection"):
            let selection = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["selection"] ?? NSNull()
            graph["selection"] = selection
            return json(["selection": selection])
        case ("GET", GraphPreviewAPI.graphID) where path.contains("graphs"):
            return json(["graph": graph])
        default:
            return (404, Data(#"{"error":{"code":"NOT_FOUND","message":"Not in the preview"}}"#.utf8))
        }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func json(_ value: Any) -> (Int, Data) {
        (200, (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
    }

    private func query(_ body: Data) -> (Int, Data) {
        let text = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["query"] as? String ?? ""
        if text.contains("BROKEN") { return (422, Data(#"{"error":{"code":"GRAPH_QUERY_INVALID","message":"Expected MATCH but found BROKEN at position 0"}}"#.utf8)) }
        var nodes: [String] = []
        if text.contains("Machine") { nodes = ["engine", "enigma"] }
        if text.contains("Person") { nodes = ["ada", "babbage", "turing"] }
        return json(["result": ["nodeIds": nodes, "edgeIds": [], "rowCount": nodes.count, "rows": [], "truncated": false] as [String: Any]])
    }

    private func apply(_ body: Data) {
        guard let operations = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["operations"] as? [[String: Any]],
              var document = graph["document"] as? [String: Any] else { return }
        func upsert(_ collection: String, _ item: [String: Any]) {
            var items = document[collection] as? [[String: Any]] ?? []
            if let index = items.firstIndex(where: { $0["id"] as? String == item["id"] as? String }) { items[index] = item } else { items.append(item) }
            document[collection] = items
        }
        for operation in operations {
            switch operation["op"] as? String {
            case "upsert_node": if let item = operation["node"] as? [String: Any] { upsert("nodes", item) }
            case "upsert_edge": if let item = operation["edge"] as? [String: Any] { upsert("edges", item) }
            case "upsert_query": if let item = operation["query"] as? [String: Any] { upsert("queries", item) }
            case "delete":
                guard let collection = operation["collection"] as? String, let id = operation["id"] as? String else { continue }
                document[collection] = (document[collection] as? [[String: Any]])?.filter { $0["id"] as? String != id }
                if collection == "nodes" {
                    document["edges"] = (document["edges"] as? [[String: Any]])?.filter { $0["source"] as? String != id && $0["target"] as? String != id }
                }
            default: break
            }
        }
        graph["document"] = document
        graph["revision"] = (graph["revision"] as? Int ?? 0) + 1
    }
}
#endif
