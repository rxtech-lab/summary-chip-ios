import Foundation

/// One step of an agent turn, independent of which CLI produced it.
public enum LocalAgentEvent: Equatable, Sendable, Codable {
    case sessionStarted(String)
    case textDelta(String)
    /// The current block of text ended, so anything unspoken can be spoken now.
    case textEnded
    case toolStarted(id: String, name: String, input: Data)
    case toolFinished(id: String, output: String, isError: Bool)
    case turnFinished
    case failed(String)
}

private func json(_ line: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

private func encoded(_ value: Any?) -> Data {
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else { return Data("{}".utf8) }
    return data
}

public let libraryUnavailableMessage = "The agent couldn't connect to your Chippy library. Check your connection and try again."

/// `mcp__chippy_app__search_summaries` reads as `search_summaries` in the transcript.
func displayToolName(_ raw: String) -> String {
    let prefix = "mcp__\(LocalAgentCommand.mcpServerName)__"
    return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
}

/// Claude Code's `--output-format stream-json`.
public struct ClaudeStreamParser: Sendable {
    /// The CLI's own lookup of deferred tools isn't something the user asked for.
    private static let hiddenTools: Set<String> = ["ToolSearch"]
    private var hiddenToolIDs = Set<String>()
    private var seenToolIDs = Set<String>()

    public init() {}

    public mutating func parse(_ line: Data) -> [LocalAgentEvent] {
        guard let event = json(line) else { return [] }
        switch event["type"] as? String {
        case "system":
            guard event["subtype"] as? String == "init", let session = event["session_id"] as? String else { return [] }
            return [.sessionStarted(session)] + Self.libraryFailure(event)
        case "stream_event":
            return streamEvent(event["event"] as? [String: Any] ?? [:])
        case "assistant":
            return toolUses(event)
        case "user":
            return toolResults(event)
        case "result":
            if event["is_error"] as? Bool == true {
                return [.failed(event["result"] as? String ?? "Claude Code couldn't finish that request.")]
            }
            return [.turnFinished]
        default:
            return []
        }
    }

    /// Without this, the agent would answer questions about the user's library from nothing.
    private static func libraryFailure(_ event: [String: Any]) -> [LocalAgentEvent] {
        let servers = event["mcp_servers"] as? [[String: Any]] ?? []
        guard let status = servers.first(where: { $0["name"] as? String == LocalAgentCommand.mcpServerName })?["status"] as? String,
              status == "failed" || status == "needs-auth" else { return [] }
        return [.failed(libraryUnavailableMessage)]
    }

    private func streamEvent(_ event: [String: Any]) -> [LocalAgentEvent] {
        switch event["type"] as? String {
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { return [.textDelta(text)] }
            return []
        case "message_stop":
            return [.textEnded]
        default:
            return []
        }
    }

    private mutating func toolUses(_ event: [String: Any]) -> [LocalAgentEvent] {
        let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.compactMap { block in
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String,
                  let name = block["name"] as? String, seenToolIDs.insert(id).inserted else { return nil }
            if Self.hiddenTools.contains(name) { hiddenToolIDs.insert(id); return nil }
            return .toolStarted(id: id, name: displayToolName(name), input: encoded(block["input"]))
        }
    }

    private func toolResults(_ event: [String: Any]) -> [LocalAgentEvent] {
        let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.compactMap { block in
            guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                  !hiddenToolIDs.contains(id) else { return nil }
            return .toolFinished(id: id, output: Self.text(block["content"]), isError: block["is_error"] as? Bool == true)
        }
    }

    private static func text(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

/// Requests and notifications of `codex app-server`.
public struct CodexRPC: Sendable {
    public enum Message: Equatable, Sendable {
        case response(id: Int, result: Data)
        case responseError(id: Int, message: String)
        /// The agent wants something decided, which nobody is present to do.
        case serverRequest(id: LocalJSONRPCID, method: String)
        case events([LocalAgentEvent])
        case turnStarted(String)
        /// Whether the Chippy server came up: true when ready, false when it won't.
        case libraryReady(Bool)
    }

    /// Messages that have streamed at least one delta.
    private var streamedMessages = Set<String>()

    public init() {}

    public mutating func parse(_ line: Data) -> Message? {
        guard let object = json(line) else { return nil }
        if let method = object["method"] as? String {
            if let id = LocalJSONRPCID(object["id"]) { return .serverRequest(id: id, method: method) }
            return notification(method, params: object["params"] as? [String: Any] ?? [:])
        }
        guard let id = object["id"] as? Int else { return nil }
        if let error = object["error"] as? [String: Any] {
            return .responseError(id: id, message: error["message"] as? String ?? "Codex rejected the request.")
        }
        return .response(id: id, result: encoded(object["result"]))
    }

    private mutating func notification(_ method: String, params: [String: Any]) -> Message? {
        switch method {
        case "mcpServer/startupStatus/updated":
            guard params["name"] as? String == LocalAgentCommand.mcpServerName else { return nil }
            switch params["status"] as? String {
            case "ready": return .libraryReady(true)
            case "failed", "cancelled": return .libraryReady(false)
            default: return nil
            }
        case "turn/started":
            return ((params["turn"] as? [String: Any])?["id"] as? String).map { .turnStarted($0) }
        case "item/agentMessage/delta", "item/agent_message/delta":
            if let item = params["itemId"] as? String { streamedMessages.insert(item) }
            return (params["delta"] as? String).map { .events([.textDelta($0)]) }
        case "item/started":
            return Self.itemStarted(params["item"] as? [String: Any] ?? [:]).map { .events([$0]) }
        case "item/completed":
            let item = params["item"] as? [String: Any] ?? [:]
            // A message that arrives whole still has to be heard.
            if item["type"] as? String == "agentMessage", let id = item["id"] as? String,
               !streamedMessages.contains(id), let text = item["text"] as? String, !text.isEmpty {
                return .events([.textDelta(text), .textEnded])
            }
            return Self.itemCompleted(item).map { .events([$0]) }
        case "turn/completed", "turn/failed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            if turn["status"] as? String == "failed" || method == "turn/failed" {
                return .events([.failed(Self.message(turn["error"]) ?? "Codex couldn't finish that request.")])
            }
            return .events([.turnFinished])
        default:
            // `error` notifications repeat in turn/completed, which is what ends the turn.
            return nil
        }
    }

    private static func itemStarted(_ item: [String: Any]) -> LocalAgentEvent? {
        guard let id = item["id"] as? String else { return nil }
        switch item["type"] as? String {
        case "mcpToolCall":
            return .toolStarted(id: id, name: item["tool"] as? String ?? "tool", input: encoded(item["arguments"]))
        case "commandExecution":
            return .toolStarted(id: id, name: "shell", input: encoded(["command": item["command"] ?? ""]))
        case "webSearch":
            return .toolStarted(id: id, name: "web_search", input: encoded(["query": item["query"] ?? ""]))
        default:
            return nil
        }
    }

    private static func itemCompleted(_ item: [String: Any]) -> LocalAgentEvent? {
        guard let id = item["id"] as? String else { return nil }
        switch item["type"] as? String {
        case "agentMessage":
            return .textEnded
        case "mcpToolCall":
            if let error = message(item["error"]) { return .toolFinished(id: id, output: error, isError: true) }
            let result = item["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]] ?? []
            let output = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return .toolFinished(id: id, output: output, isError: item["status"] as? String == "failed" || result?["isError"] as? Bool == true)
        case "commandExecution":
            let failed = (item["exitCode"] as? Int).map { $0 != 0 } ?? (item["status"] as? String != "completed")
            return .toolFinished(id: id, output: item["aggregatedOutput"] as? String ?? "", isError: failed)
        case "webSearch":
            return .toolFinished(id: id, output: "", isError: false)
        default:
            return nil
        }
    }

    /// Provider failures arrive as a JSON document inside the message, so dig out the readable part.
    private static func message(_ error: Any?) -> String? {
        guard let raw = (error as? [String: Any])?["message"] as? String else { return nil }
        guard let nested = json(Data(raw.utf8)) else { return raw }
        return ((nested["error"] as? [String: Any])?["message"] as? String) ?? raw
    }

    /// The account can't use the model in the user's Codex config, which a default model can fix.
    public static func isUnsupportedModel(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("model_not_found") || (text.contains("model") && text.contains("not supported"))
    }

    public static func defaultModel(fromModelList result: Data) -> String? {
        let models = json(result)?["data"] as? [[String: Any]] ?? []
        let visible = models.filter { $0["hidden"] as? Bool != true }
        return ((visible.first { $0["isDefault"] as? Bool == true } ?? visible.first)?["id"]) as? String
    }

    public static func threadID(fromThreadStart result: Data) -> String? {
        (json(result)?["thread"] as? [String: Any])?["id"] as? String
    }

    // MARK: Outgoing

    public static func line(id: Int? = nil, method: String, params: [String: Any]) -> Data {
        var object: [String: Any] = ["method": method, "params": params]
        if let id { object["id"] = id }
        return ((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) + Data("\n".utf8)
    }

    public static func rejectRequest(id: LocalJSONRPCID) -> Data {
        let object: [String: Any] = ["id": id.value, "error": ["code": -32601, "message": "Live voice can't answer this request."]]
        return ((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) + Data("\n".utf8)
    }

    public static func initializeParams(version: String) -> [String: Any] {
        ["clientInfo": ["name": "Chippy", "title": "Chippy", "version": version], "capabilities": [String: Any]()]
    }

    /// Reads and inspects only, and never stops to ask: nobody is at the keyboard.
    public static func threadStartParams(cwd: String, instructions: String) -> [String: Any] {
        ["cwd": cwd, "approvalPolicy": "never", "sandbox": "read-only", "developerInstructions": instructions]
    }

    public static func turnStartParams(threadID: String, text: String, model: String?) -> [String: Any] {
        var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
        if let model { params["model"] = model }
        return params
    }
}

public struct LocalJSONRPCID: Equatable, Sendable {
    let number: Int?
    let string: String?

    init?(_ raw: Any?) {
        if let value = raw as? Int { number = value; string = nil }
        else if let value = raw as? String { number = nil; string = value }
        else { return nil }
    }

    var value: Any { number.map { $0 as Any } ?? string as Any }
}

public enum ClaudeInput {
    public static func userMessage(_ text: String) -> Data {
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        return ((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) + Data("\n".utf8)
    }
}

public struct LocalAgentSDKCommand: Codable, Sendable {
    public let text: String?
    public init(text: String? = nil) { self.text = text }
}
