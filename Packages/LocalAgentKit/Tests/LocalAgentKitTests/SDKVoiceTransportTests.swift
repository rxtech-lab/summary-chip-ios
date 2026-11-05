import Foundation
import Testing
@testable import LocalAgentKit

@Test func sdkVoiceEventsSurviveXPCEncoding() throws {
    let events: [LocalAgentEvent] = [
        .sessionStarted("session"), .textDelta("你好"), .textEnded,
        .toolStarted(id: "call", name: "search", input: Data("{\"query\":\"voice\"}".utf8)),
        .toolFinished(id: "call", output: "result", isError: false), .turnFinished, .failed("Disconnected")
    ]
    for event in events {
        #expect(try JSONDecoder().decode(LocalAgentEvent.self, from: JSONEncoder().encode(event)) == event)
    }
}

@Test func sdkVoiceCommandsDistinguishInterruptFromText() throws {
    for text in [nil, "Explain the graph"] as [String?] {
        let data = try JSONEncoder().encode(LocalAgentSDKCommand(text: text))
        #expect(try JSONDecoder().decode(LocalAgentSDKCommand.self, from: data).text == text)
    }
    #expect(LiveVoiceEngine(saved: "codex") == .codex)
    #expect(LiveVoiceEngine(saved: "codexRealtime") == .codexRealtime)
    #expect(LiveVoiceEngine.codexRealtime.localAgent == .codex)
}

@Test func realtimeSignalingSurvivesXPCEncoding() throws {
    let events: [LocalRealtimeEvent] = [
        .init(kind: .answer, text: "v=0\r\ns=-\r\n"), .init(kind: .assistantDelta, text: " 你好"),
        .init(kind: .assistantDone), .init(kind: .userTranscript, text: "Hello"),
        .init(kind: .error, text: "Failed"), .init(kind: .closed),
        .init(kind: .tool, tool: .toolFinished(id: "call", output: "result", isError: false)),
        .init(kind: .turnEnded),
    ]
    for event in events {
        #expect(try JSONDecoder().decode(LocalRealtimeEvent.self, from: JSONEncoder().encode(event)) == event)
    }
}

@Test func sdkToolNamesReachTheTranscriptVocabulary() {
    let name = LocalToolOutput.chatToolName("mcp__chippy_app__select_graph_elements")
    #expect(name == "selectGraphElements")
    #expect(LocalToolOutput.changesOpenDocument(toolName: LocalToolOutput.chatToolName("mcp__chippy_app__update_graph")))
}

/// The shape Codex reports for an MCP call, with the tool's JSON inside a text block.
@Test func wrappedMCPResultStillSelectsInTheOpenGraph() throws {
    let selection = #"{\"selection\":{\"mode\":\"highlight\",\"nodeIds\":[\"heavybit\"],\"edgeIds\":[]}}"#
    let result = #"{"content":[{"type":"text","text":"\#(selection)"}],"structuredContent":null}"#
    let data = LocalToolOutput.chatOutput(toolName: "selectGraphElements", output: result)
    let output = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let graphSelection = try #require(output["graphSelection"] as? [String: Any])
    #expect(graphSelection["nodeIds"] as? [String] == ["heavybit"])
}

@Test func wrappedPlainTextIsReadableInTheTranscript() throws {
    let data = LocalToolOutput.chatOutput(toolName: "getGraph", output: #"{"content":[{"type":"text","text":"Saved."}]}"#)
    #expect(try JSONSerialization.jsonObject(with: data) as? [String: String] == ["text": "Saved."])
}

@Test func realtimeForwardsMCPCallsFromTheBackingThread() throws {
    let started = Data(#"{"type":"mcpToolCall","id":"call","server":"chippy_app","tool":"get_graph","status":"inProgress","arguments":{"graphId":"g"}}"#.utf8)
    guard case .toolStarted(let id, let name, let input)? = LocalRealtimeEvent.toolEvent(method: "item/started", item: started)?.tool else {
        Issue.record("Expected a started tool"); return
    }
    #expect(id == "call" && name == "mcp__chippy_app__get_graph")
    #expect(try JSONSerialization.jsonObject(with: input) as? [String: String] == ["graphId": "g"])

    let completed = Data(#"{"type":"mcpToolCall","id":"call","server":"chippy_app","tool":"get_graph","status":"completed","result":{"content":[{"type":"text","text":"ok"}]},"error":null}"#.utf8)
    guard case .toolFinished(_, let output, false)? = LocalRealtimeEvent.toolEvent(method: "item/completed", item: completed)?.tool else {
        Issue.record("Expected a finished tool"); return
    }
    #expect(output.contains("ok"))

    let failed = Data(#"{"type":"mcpToolCall","id":"call","server":"chippy_app","tool":"get_graph","status":"failed","error":{"message":"Denied"}}"#.utf8)
    #expect(LocalRealtimeEvent.toolEvent(method: "item/completed", item: failed)?.tool == .toolFinished(id: "call", output: "Denied", isError: true))
}

@Test func realtimeIgnoresThreadItemsThatAreNotMCPCalls() {
    let message = Data(#"{"type":"agentMessage","id":"m","text":"Hello"}"#.utf8)
    #expect(LocalRealtimeEvent.toolEvent(method: "item/started", item: message) == nil)
}

@Test func appToolsLaunchSurvivesXPCWithoutLeakingTokenInArguments() throws {
    var launch = LocalAgentLaunch(kind: .codex, mcpURL: URL(string: "https://example.com/mcp")!, mcpToken: "remote-secret", instructions: "Voice")
    launch.appToolsURL = URL(string: "http://127.0.0.1:12345/mcp")!
    launch.appToolsToken = "local-secret"
    let decoded = try JSONDecoder().decode(LocalAgentLaunch.self, from: JSONEncoder().encode(launch))
    #expect(decoded == launch)
    let arguments = LocalAgentCommand.arguments(for: decoded).joined(separator: " ")
    #expect(arguments.contains("mcp_servers.chippy_ui.url=\"http://127.0.0.1:12345/mcp\""))
    #expect(arguments.contains("CHIPPY_APP_TOOLS_TOKEN"))
    #expect(!arguments.contains("local-secret"))
    #expect(!arguments.contains("remote-secret"))
    #expect(LocalAgentCommand.environment(for: decoded)["CHIPPY_APP_TOOLS_TOKEN"] == "local-secret")
}
