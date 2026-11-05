import Foundation
import LocalAgentKit
import RxAgentCore
import RxAgentClients

/// Agent SDK execution stays in the unsandboxed XPC service.
actor SDKAgentSession {
    private let client: any AgentClient
    private let launch: LocalAgentLaunch
    private let directory: URL
    private let emit: @Sendable (Data) -> Void
    private var sessionID: String?
    private let threadID = AgentThreadID()
    private var turn: UUID?
    private var task: Task<Void, Never>?
    private var names: [String: String] = [:]
    private var closed = false
    private var commandRevision = UUID()

    init(launch: LocalAgentLaunch, binary: String, environment: [String: String], directory: URL,
         emit: @escaping @Sendable (Data) -> Void) {
        self.launch = launch; self.directory = directory; self.emit = emit
        let environment = environment.merging(LocalAgentCommand.environment(for: launch)) { _, new in new }
        switch launch.kind {
        case .codex:
            client = CodexClient(binaryPath: binary, approvalPolicy: .never, sandbox: .readOnly, configOverrides: ["mcp_servers.\(LocalAgentCommand.mcpServerName).default_tools_approval_mode=\"approve\""], environment: environment)
        case .claudeCode:
            client = ClaudeCodeClient(binaryPath: binary, environment: environment)
        }
    }

    func receive(_ data: Data) async {
        guard !closed, let command = try? JSONDecoder().decode(LocalAgentSDKCommand.self, from: data) else { return }
        let revision = UUID(); commandRevision = revision
        await cancel()
        guard !closed, commandRevision == revision, let text = command.text else { return }
        let id = UUID(); turn = id
        let request = AgentSendRequest(turnID: id, threadID: threadID, resumeSessionID: sessionID,
            prompt: text, workingDirectory: directory, model: launch.model, contextText: launch.instructions,
            mcpServers: [.http(name: LocalAgentCommand.mcpServerName, url: launch.mcpURL,
                headers: ["Authorization": launch.kind == .codex ? "Bearer \(launch.mcpToken)" : "Bearer ${\(LocalAgentCommand.tokenEnvironmentKey)}"])],
            allowedTools: ["mcp__\(LocalAgentCommand.mcpServerName)__*", "Read", "Glob", "Grep", "WebSearch", "WebFetch"])
        task = Task { [weak self, client] in
            for await event in client.send(request) {
                guard !Task.isCancelled else { return }
                await self?.handle(event, turn: id)
            }
        }
    }

    private func handle(_ event: AgentEvent, turn id: UUID) {
        guard !closed, turn == id else { return }
        let value: LocalAgentEvent?
        switch event {
        case .sessionStarted(let session): sessionID = session.nativeSessionID; value = .sessionStarted(session.nativeSessionID)
        case .textDelta(let text): value = .textDelta(text)
        case .toolCallStarted(let id, let name): names[id] = name; value = nil
        case .toolCallInput(let id, let input):
            value = .toolStarted(id: id, name: names[id] ?? "Tool", input: (try? JSONEncoder().encode(input)) ?? Data())
        case .toolCallResult(let id, let content, let error): value = .toolFinished(id: id, output: content, isError: error)
        case .turnEnded(let result):
            if let native = result.nativeSessionID { sessionID = native }
            value = result.isError ? .failed("The agent could not complete this turn.") : .turnFinished
        case .failed(let error): value = .failed(error.description)
        default: value = nil
        }
        if let value, let data = try? JSONEncoder().encode(value) { emit(data) }
    }

    func cancel() async {
        let old = turn; turn = nil
        task?.cancel(); task = nil; names = [:]
        if let old { await client.cancel(turn: old) }
    }
    func close() async { closed = true; await cancel() }
}
