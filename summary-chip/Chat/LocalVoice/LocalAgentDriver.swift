#if os(macOS)
import Foundation
import LocalAgentKit
import OSLog

let runnerLogger = Logger(subsystem: "com.rxlab.summary-chip", category: "LocalVoice")

/// One running agent, the same to the voice session whichever CLI it is.
@MainActor
protocol LocalAgentDriver: AnyObject {
    var onEvent: ((LocalAgentEvent) -> Void)? { get set }
    func start() async throws
    func send(_ text: String)
    /// Abandons the running turn; `send` can be called straight after.
    func interrupt()
    func stop()
}

/// Claude Code stays running between turns, reading messages from stdin. Interrupting means
/// ending the process and resuming the session, which also keeps what was said so far.
@MainActor
final class ClaudeCodeDriver: LocalAgentDriver {
    var onEvent: ((LocalAgentEvent) -> Void)?
    private var launch: LocalAgentLaunch
    private let runner: LocalAgentRunnerClient
    private var processID: String?
    private var parser = ClaudeStreamParser()
    private var isRestarting = false
    private var queued: [String] = []

    init(launch: LocalAgentLaunch, runner: LocalAgentRunnerClient = .shared) {
        self.launch = launch
        self.runner = runner
    }

    func start() async throws {
        let id = UUID().uuidString
        parser = ClaudeStreamParser()
        try await runner.startAgent(launch, id: id, handler: .init(
            onLine: { [weak self] line in self?.receive(line) },
            onExit: { [weak self] status, message in self?.exited(id: id, status: status, message: message) }
        ))
        processID = id
    }

    func send(_ text: String) {
        guard let processID, !isRestarting else {
            queued.append(text)
            return
        }
        runner.write(id: processID, data: ClaudeInput.userMessage(text))
    }

    func interrupt() {
        guard let processID, !isRestarting else { return }
        runner.terminate(id: processID)
        self.processID = nil
        isRestarting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.start()
                self.isRestarting = false
                let messages = self.queued
                self.queued = []
                for message in messages { self.send(message) }
            } catch {
                self.isRestarting = false
                self.onEvent?(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        if let processID { runner.terminate(id: processID) }
        processID = nil
        onEvent = nil
    }

    private func receive(_ line: Data) {
        for event in parser.parse(line) {
            if case .sessionStarted(let session) = event { launch.resumeSessionID = session }
            onEvent?(event)
        }
    }

    private func exited(id: String, status: Int32, message: String?) {
        guard id == processID else { return }
        processID = nil
        runnerLogger.error("Claude Code exited \(status): \(message ?? "", privacy: .public)")
        onEvent?(.failed(message.map(LocalAgentErrorText.lastLine) ?? String(localized: "Claude Code stopped unexpectedly.")))
    }
}

/// Codex's app server speaks JSON-RPC over stdio, with one thread for the voice session.
@MainActor
final class CodexDriver: LocalAgentDriver {
    private enum RequestID {
        static let initialize = 1
        static let threadStart = 2
        static let turnStart = 3
        static let modelList = 4
        static let turnInterrupt = 5
    }

    var onEvent: ((LocalAgentEvent) -> Void)?
    private let launch: LocalAgentLaunch
    private let runner: LocalAgentRunnerClient
    private var rpc = CodexRPC()
    private let directory: String
    private let processID = UUID().uuidString
    private var isRunning = false
    private var threadID: String?
    private var turnID: String?
    private var model: String?
    private var lastPrompt: String?
    private var queued: [String] = []
    private var isTurnActive = false
    /// Events of an interrupted turn keep arriving until Codex confirms it ended.
    private var isInterrupting = false
    private var ready: CheckedContinuation<Void, Error>?
    private var isLibraryReady = false

    init(launch: LocalAgentLaunch, directory: String, runner: LocalAgentRunnerClient = .shared) {
        self.launch = launch
        self.directory = directory
        self.runner = runner
        model = launch.model
    }

    func start() async throws {
        try await runner.startAgent(launch, id: processID, handler: .init(
            onLine: { [weak self] line in self?.receive(line) },
            onExit: { [weak self] status, message in self?.exited(status: status, message: message) }
        ))
        isRunning = true
        write(id: RequestID.initialize, method: "initialize", params: CodexRPC.initializeParams(version: Bundle.main.marketingVersion))
        // The thread exists before the first utterance, so the first reply starts sooner. Its first
        // turn would also see no Chippy tools if the server were still connecting.
        let processID = processID
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.isRunning, self.processID == processID else { return }
            self.finishWaiting(throwing: LocalVoiceFailure(libraryUnavailableMessage))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { ready = $0 }
    }

    func send(_ text: String) {
        guard threadID != nil, !isInterrupting, !isTurnActive else {
            queued.append(text)
            return
        }
        startTurn(text)
    }

    func interrupt() {
        queued = []
        guard isTurnActive, !isInterrupting, let threadID else { return }
        isInterrupting = true
        guard let turnID else { return }
        write(id: RequestID.turnInterrupt, method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
    }

    func stop() {
        if isRunning { runner.terminate(id: processID) }
        isRunning = false
        finishWaiting(throwing: CancellationError())
        onEvent = nil
    }

    private func startTurn(_ text: String) {
        guard let threadID else { return }
        lastPrompt = text
        isTurnActive = true
        turnID = nil
        write(id: RequestID.turnStart, method: "turn/start", params: CodexRPC.turnStartParams(threadID: threadID, text: text, model: model))
    }

    private func write(id: Int?, method: String, params: [String: Any]) {
        runner.write(id: processID, data: CodexRPC.line(id: id, method: method, params: params))
    }

    private func receive(_ line: Data) {
        switch rpc.parse(line) {
        case .response(let id, let result): response(id: id, result: result)
        case .responseError(let id, let message):
            // The turn may have ended first, which is what interrupting wanted anyway.
            if id != RequestID.turnInterrupt { failed(message) }
        case .serverRequest(let id, let method):
            // Approvals are off for the session, so anything asking is declined rather than left hanging.
            runnerLogger.info("Declining Codex request \(method, privacy: .public)")
            runner.write(id: processID, data: CodexRPC.rejectRequest(id: id))
        case .turnStarted(let id):
            turnID = id
            // Interrupted before Codex said which turn was running.
            if isInterrupting, let threadID { write(id: RequestID.turnInterrupt, method: "turn/interrupt", params: ["threadId": threadID, "turnId": id]) }
        case .libraryReady(let isReady):
            guard isReady else {
                failed(libraryUnavailableMessage)
                return
            }
            isLibraryReady = true
            finishWaitingIfReady()
        case .events(let events): events.forEach(handle)
        case nil: break
        }
    }

    private func response(id: Int, result: Data) {
        switch id {
        case RequestID.initialize:
            write(id: nil, method: "initialized", params: [:])
            write(id: RequestID.threadStart, method: "thread/start",
                  params: CodexRPC.threadStartParams(cwd: directory, instructions: launch.instructions))
        case RequestID.threadStart:
            threadID = CodexRPC.threadID(fromThreadStart: result)
            if threadID == nil {
                finishWaiting(throwing: LocalVoiceFailure(String(localized: "Codex couldn't start a conversation.")))
            } else {
                finishWaitingIfReady()
            }
        case RequestID.modelList:
            guard let fallback = CodexRPC.defaultModel(fromModelList: result), let lastPrompt else {
                failed(String(localized: "Codex has no model this account can use."))
                return
            }
            model = fallback
            startTurn(lastPrompt)
        default:
            break
        }
    }

    private func handle(_ event: LocalAgentEvent) {
        switch event {
        case .turnFinished:
            endTurn(event)
        case .failed(let message):
            // The user's configured model may not be available to their account.
            if !isInterrupting, model == nil, CodexRPC.isUnsupportedModel(message) {
                write(id: RequestID.modelList, method: "model/list", params: [:])
                return
            }
            endTurn(event)
        default:
            if !isInterrupting { onEvent?(event) }
        }
    }

    private func endTurn(_ event: LocalAgentEvent) {
        let wasInterrupting = isInterrupting
        isInterrupting = false
        isTurnActive = false
        turnID = nil
        if !wasInterrupting { onEvent?(event) }
        if !queued.isEmpty { startTurn(queued.removeFirst()) }
    }

    private func failed(_ message: String) {
        finishWaiting(throwing: LocalVoiceFailure(message))
        onEvent?(.failed(message))
    }

    private func exited(status: Int32, message: String?) {
        isRunning = false
        runnerLogger.error("Codex exited \(status): \(message ?? "", privacy: .public)")
        failed(message.map(LocalAgentErrorText.lastLine) ?? String(localized: "Codex stopped unexpectedly."))
    }

    private func finishWaitingIfReady() {
        if threadID != nil, isLibraryReady { finishWaiting(throwing: nil) }
    }

    private func finishWaiting(throwing error: Error?) {
        guard let ready else { return }
        self.ready = nil
        if let error { ready.resume(throwing: error) } else { ready.resume() }
    }
}

enum LocalAgentErrorText {
    /// CLIs end stderr with the message that matters, after any stack or log output.
    static func lastLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        return String(line.prefix(300))
    }
}

private extension Bundle {
    var marketingVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}
#endif
