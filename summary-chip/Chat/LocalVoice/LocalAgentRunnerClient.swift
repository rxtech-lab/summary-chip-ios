#if os(macOS)
import Foundation
import LocalAgentKit
import RxAgentCore

/// The app's side of the runner service, which launches agents outside the app's sandbox.
@MainActor
final class LocalAgentRunnerClient {
    struct ProcessHandler {
        let onLine: (Data) -> Void
        let onExit: (Int32, String?) -> Void
    }

    static let shared = LocalAgentRunnerClient()

    private var connection: NSXPCConnection?
    private var handlers: [String: ProcessHandler] = [:]
    var onVoiceSetupProgress: ((LocalVoiceSetupProgress) -> Void)?

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> LocalAgentRunnerProtocol? {
        let connection = connection ?? makeConnection()
        return connection.remoteObjectProxyWithErrorHandler(onError) as? LocalAgentRunnerProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: localAgentRunnerServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: LocalAgentRunnerProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: LocalAgentRunnerClientProtocol.self)
        connection.exportedObject = LocalAgentRunnerReceiver(client: self)
        let lost: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionLost() } }
        }
        connection.invalidationHandler = lost
        connection.interruptionHandler = lost
        connection.resume()
        self.connection = connection
        return connection
    }

    private func connectionLost() {
        connection?.invalidate()
        connection = nil
        let running = handlers
        handlers = [:]
        for handler in running.values { handler.onExit(-1, String(localized: "The local agent service stopped unexpectedly.")) }
    }

    /// Runs one request that ends in a reply; a lost connection ends it too, whichever comes first.
    private func request<Value: Sendable>(_ body: (LocalAgentRunnerProtocol, @escaping @Sendable (Value) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = proxy(onError: { once.fail($0) }) else {
                once.fail(URLError(.cannotConnectToHost))
                return
            }
            body(proxy) { once.succeed($0) }
        }
    }

    func status() async throws -> LocalAgentRunnerStatus {
        let data: Data = try await request { proxy, reply in proxy.status(reply: reply) }
        return try JSONDecoder().decode(LocalAgentRunnerStatus.self, from: data)
    }

    func startAgent(_ launch: LocalAgentLaunch, id: String, handler: ProcessHandler) async throws {
        let encoded = try JSONEncoder().encode(launch)
        try await start(id: id, handler: handler) { proxy, reply in proxy.startAgent(id: id, request: encoded, reply: reply) }
    }

    func models(for kind: LocalAgentKind) async throws -> [AgentModelOption] {
        let data: Data = try await request { proxy, reply in proxy.agentModels(kind: kind.rawValue, reply: reply) }
        return try JSONDecoder().decode([AgentModelOption].self, from: data)
    }

    func startSpeechWorker(id: String, modelID: String?, seed: Int, handler: ProcessHandler) async throws {
        try await start(id: id, handler: handler) { proxy, reply in proxy.startSpeechWorker(id: id, modelID: modelID, seed: seed, reply: reply) }
    }

    private func start(id: String, handler: ProcessHandler,
                       _ body: (LocalAgentRunnerProtocol, @escaping @Sendable (String?) -> Void) -> Void) async throws {
        // Registered first: output can arrive before the reply does.
        handlers[id] = handler
        do {
            let failure: String? = try await request(body)
            if let failure { throw LocalVoiceFailure(failure) }
        } catch {
            handlers[id] = nil
            throw error
        }
    }

    func write(id: String, data: Data) {
        proxy(onError: { _ in })?.write(id: id, data: data)
    }

    /// Output still in flight is dropped along with the handler.
    func terminate(id: String) {
        handlers[id] = nil
        proxy(onError: { _ in })?.terminate(id: id)
    }

    func prepareVoice() async throws {
        let failure: String? = try await request { proxy, reply in proxy.prepareVoice(reply: reply) }
        if let failure { throw LocalVoiceFailure(failure) }
    }

    func downloadVoiceModel(_ model: LocalVoiceModel) async throws {
        let failure: String? = try await request { proxy, reply in
            proxy.downloadVoiceModel(repository: model.repository, revision: model.revision, reply: reply)
        }
        if let failure { throw LocalVoiceFailure(failure) }
    }

    func manageVoiceModel(id: String, action: String) async throws {
        let failure: String? = try await request { proxy, reply in proxy.manageVoiceModel(id: id, action: action, reply: reply) }
        if let failure { throw LocalVoiceFailure(failure) }
    }

    func cancelVoiceSetup() {
        proxy(onError: { _ in })?.cancelVoiceSetup()
    }

    fileprivate func received(line: Data, id: String) {
        handlers[id]?.onLine(line)
    }

    fileprivate func exited(id: String, status: Int32, message: String?) {
        handlers.removeValue(forKey: id)?.onExit(status, message)
    }
}

nonisolated struct LocalVoiceFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Resumes exactly once, since XPC can report a connection error after a reply or instead of one.
nonisolated private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }

    func succeed(_ value: Value) { take()?.resume(returning: value) }
    func fail(_ error: Error) { take()?.resume(throwing: error) }
}

/// Receives callbacks on XPC's queue. `DispatchQueue.main` keeps them strictly in order,
/// which a separate Task for each one wouldn't promise.
nonisolated private final class LocalAgentRunnerReceiver: NSObject, LocalAgentRunnerClientProtocol, @unchecked Sendable {
    private weak var client: LocalAgentRunnerClient?

    init(client: LocalAgentRunnerClient) { self.client = client }

    private func onMain(_ body: @escaping @MainActor (LocalAgentRunnerClient) -> Void) {
        DispatchQueue.main.async { [weak client] in
            MainActor.assumeIsolated {
                if let client { body(client) }
            }
        }
    }

    func processLine(id: String, line: Data) {
        onMain { $0.received(line: line, id: id) }
    }

    func processExited(id: String, status: Int32, message: String?) {
        onMain { $0.exited(id: id, status: status, message: message) }
    }

    func voiceSetupProgress(_ data: Data) {
        guard let progress = try? JSONDecoder().decode(LocalVoiceSetupProgress.self, from: data) else { return }
        onMain { $0.onVoiceSetupProgress?(progress) }
    }
}
#endif
