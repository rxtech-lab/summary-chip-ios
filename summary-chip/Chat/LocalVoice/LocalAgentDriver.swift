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

/// The SDK owns CLI protocol handling in the runner. Only normalized events cross XPC.
@MainActor
final class SDKAgentDriver: LocalAgentDriver {
    var onEvent: ((LocalAgentEvent) -> Void)?
    private let launch: LocalAgentLaunch
    private let runner: LocalAgentRunnerClient
    private let id = UUID().uuidString
    init(launch: LocalAgentLaunch, runner: LocalAgentRunnerClient = .shared) {
        self.launch = launch; self.runner = runner
    }
    func start() async throws {
        try await runner.startAgent(launch, id: id, handler: .init(onLine: { [weak self] data in
            if let event = try? JSONDecoder().decode(LocalAgentEvent.self, from: data) { self?.onEvent?(event) }
        }, onExit: { [weak self] _, message in self?.onEvent?(.failed(message ?? "The agent service stopped.")) }))
    }
    func send(_ text: String) { write(.init(text: text)) }
    func interrupt() { write(.init()) }
    private func write(_ command: LocalAgentSDKCommand) {
        if let data = try? JSONEncoder().encode(command) { runner.write(id: id, data: data) }
    }
    func stop() { runner.terminate(id: id); onEvent = nil }
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
