import Foundation
import LocalAgentKit
import OSLog
import RxAgentClients
import RxAgentCore

let runnerLogger = Logger(subsystem: "com.rxlab.summary-chip", category: "LocalAgentRunner")

final class RunnerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = RunnerService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: LocalAgentRunnerProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: LocalAgentRunnerClientProtocol.self)
        // Agents must not outlive the app that started them, including after a crash.
        connection.invalidationHandler = { service.terminateAll() }
        connection.interruptionHandler = { service.terminateAll() }
        connection.resume()
        return true
    }
}

/// Serves one app connection. All state is confined to `queue`.
final class RunnerService: NSObject, LocalAgentRunnerProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.rxlab.summary-chip.runner")
    private weak var connection: NSXPCConnection?
    private var processes: [String: RunnerProcess] = [:]
    private var realtime: [String: SDKRealtimeSession] = [:]
    private var agents: [String: SDKAgentSession] = [:]
    private var setup: Task<Void, Never>?
    private var cancelledAgentIDs = Set<String>()
    private var invalidated = false
    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    private var client: LocalAgentRunnerClientProtocol? {
        connection?.remoteObjectProxy as? LocalAgentRunnerClientProtocol
    }

    func status(reply: @escaping @Sendable (Data) -> Void) {
        Task.detached {
            let environment = await UserEnvironment.shared.values()
            let agents = await withTaskGroup(of: LocalAgentInstall.self) { group in
                for kind in LocalAgentKind.allCases {
                    group.addTask { await UserEnvironment.shared.install(of: kind) }
                }
                return await group.reduce(into: [LocalAgentInstall]()) { $0.append($1) }
            }
            var status = LocalAgentRunnerStatus(
                agents: agents, hasUV: UserEnvironment.find("uv", in: environment) != nil,
                voiceReady: VoiceInstaller.isReady, isAppleSilicon: VoiceInstaller.isAppleSilicon
            )
            status.selectedVoiceModel = VoiceInstaller.selectedModel?.id ?? ""
            status.voiceModels = VoiceInstaller.catalogue
            status.downloadedVoiceModels = status.voiceModels.filter { VoiceInstaller.isDownloaded($0) }.map(\.id)
            status.storedVoiceModels = status.voiceModels.filter {
                FileManager.default.fileExists(atPath: VoiceInstaller.directory(for: $0).path)
            }.map(\.id)
            reply((try? JSONEncoder().encode(status)) ?? Data())
        }
    }

    func startAgent(id: String, request: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let launch = try? JSONDecoder().decode(LocalAgentLaunch.self, from: request) else {
            reply("The agent request couldn't be read.")
            return
        }
        Task.detached { [self] in
            let environment = await UserEnvironment.shared.values()
            guard let executable = UserEnvironment.find(launch.kind.executableName, in: environment) else {
                reply("\(launch.kind.displayName) isn't installed.")
                return
            }
            let directory = VoiceInstaller.root.appending(path: "workspace")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = SDKAgentSession(launch: launch, binary: executable.path, environment: environment, directory: directory) { [weak self] line in
                self?.client?.processLine(id: id, line: line)
            }
            let accepted = queue.sync {
                guard !invalidated, !cancelledAgentIDs.contains(id) else { return false }
                agents[id] = session
                return true
            }
            if accepted { reply(nil) }
            else { await session.close(); reply("Voice session cancelled.") }
        }
    }

    func startRealtime(id: String, request: Data, offer: String, reply: @escaping @Sendable (String?) -> Void) {
        guard let launch = try? JSONDecoder().decode(LocalAgentLaunch.self, from: request), launch.kind == .codex else {
            reply("Invalid Codex voice request."); return
        }
        let session = SDKRealtimeSession()
        queue.sync { realtime[id] = session }
        Task {
            do {
                let environment = await UserEnvironment.shared.values()
                guard let binary = UserEnvironment.find("codex", in: environment) else { throw NSError(domain: "Codex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install Codex first."]) }
                let directory = VoiceInstaller.root.appending(path: "workspace")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await session.start(launch: launch, offer: offer, binary: binary.path, environment: environment, directory: directory) { [weak self] data in
                    self?.client?.processLine(id: id, line: data)
                }
                reply(nil)
            } catch {
                // Left in the list, a failed session would block voice downloads and samples for good.
                queue.sync { _ = realtime.removeValue(forKey: id) }
                await session.close()
                reply(error.localizedDescription)
            }
        }
    }

    func startSpeechWorker(id: String, modelID: String?, seed: Int, reply: @escaping @Sendable (String?) -> Void) {
        let chosen = modelID == nil ? VoiceInstaller.selectedModel : VoiceInstaller.catalogue.first { $0.id == modelID }
        guard VoiceInstaller.isRuntimeReady, let model = chosen, VoiceInstaller.isDownloaded(model) else {
            reply("The on-device voice isn't installed yet.")
            return
        }
        // A second model in memory, and two voices at once, wouldn't help anyone.
        if modelID != nil, !queue.sync(execute: { processes.isEmpty && agents.isEmpty && realtime.isEmpty }) {
            reply("End voice chat before playing a sample.")
            return
        }
        guard let script = Bundle.main.url(forResource: "kokoro_worker", withExtension: "py") else {
            reply("The speech worker is missing from the app.")
            return
        }
        Task.detached { [self] in
            let environment = await UserEnvironment.shared.values()
            // -I keeps Python from importing anything from the working directory or user site.
            reply(run(id: id, executable: VoiceInstaller.python, arguments: ["-I", script.path, VoiceInstaller.directory(for: model).path, String(seed)],
                      environment: environment, directory: VoiceInstaller.root))
        }
    }

    func agentModels(kind: String, reply: @escaping @Sendable (Data) -> Void) {
        Task.detached {
            let environment = await UserEnvironment.shared.values()
            guard let kind = LocalAgentKind(rawValue: kind),
                  let executable = UserEnvironment.find(kind.executableName, in: environment) else {
                reply(Data("[]".utf8))
                return
            }
            // The same install and environment a voice session would launch.
            let client: any AgentClient = switch kind {
            case .claudeCode: ClaudeCodeClient(binaryPath: executable.path, environment: environment)
            case .codex: CodexClient(binaryPath: executable.path, environment: environment)
            }
            let models = await client.availableModels()
            reply((try? JSONEncoder().encode(models)) ?? Data("[]".utf8))
        }
    }

    private func run(id: String, executable: URL, arguments: [String], environment: [String: String], directory: URL) -> String? {
        let process = RunnerProcess(
            executable: executable, arguments: arguments, environment: environment, directory: directory,
            onLine: { [weak self] line in self?.client?.processLine(id: id, line: line) },
            onExit: { [weak self] status, message in
                guard let self else { return }
                self.queue.async { self.processes[id] = nil }
                self.client?.processExited(id: id, status: status, message: message)
            }
        )
        do {
            try process.start()
            queue.sync { processes[id] = process }
            return nil
        } catch {
            runnerLogger.error("Couldn't start \(executable.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    func write(id: String, data: Data) {
        queue.async { [self] in
            if let agent = agents[id] { Task { await agent.receive(data) } }
            else { processes[id]?.write(data) }
        }
    }

    func terminate(id: String) {
        // Gone from the list at once: whatever's asked next shouldn't have to wait for it to exit.
        queue.async { [self] in
            cancelledAgentIDs.insert(id)
            processes.removeValue(forKey: id)?.terminate()
            if let session = realtime.removeValue(forKey: id) { Task { await session.close() } }
            if let agent = agents.removeValue(forKey: id) { Task { await agent.close() } }
        }
    }

    func downloadVoiceModel(repository: String, revision: String, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard setup == nil, processes.isEmpty, agents.isEmpty, realtime.isEmpty else { reply("End voice chat and wait for the current download first."); return }
            setup = Task.detached { [weak self] in
                var failure: String?
                do {
                    var model = try await VoiceModelHub.resolve(repository, revision: revision)
                    if let existing = VoiceInstaller.catalogue.first(where: { $0.repository == repository && $0.revision == revision }) { model.id = existing.id }
                    try Task.checkCancellation()
                    try VoiceInstaller.register(model)
                    try await VoiceInstaller(model: model) { [weak self] progress in
                        guard let data = try? JSONEncoder().encode(progress) else { return }
                        self?.client?.voiceSetupProgress(data)
                    }.prepare()
                } catch { failure = error.localizedDescription }
                let result = failure
                if let self { self.queue.async { self.setup = nil; reply(result) } } else { reply(result) }
            }
        }
    }

    func manageVoiceModel(id: String, action: String, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard let model = VoiceInstaller.catalogue.first(where: { $0.id == id }) else { reply("Unknown voice model."); return }
            guard setup == nil, processes.isEmpty, agents.isEmpty, realtime.isEmpty else {
                reply("End voice chat and wait for any download to finish before changing models."); return
            }
            switch action {
            case "download": prepareVoice(model: model, reply: reply)
            case "select":
                guard VoiceInstaller.isDownloaded(model) else { reply("Download this model first."); return }
                UserDefaults.standard.set(id, forKey: "selectedVoiceModel")
                reply(nil)
            case "delete":
                do {
                    let directory = VoiceInstaller.directory(for: model)
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                    // Keep the selection explicit: a deleted selected model must be downloaded again.
                    reply(nil)
                } catch { reply(error.localizedDescription) }
            default: reply("Unknown model action.")
            }
        }
    }

    func prepareVoice(reply: @escaping @Sendable (String?) -> Void) {
        guard let model = VoiceInstaller.selectedModel else { reply("Choose and download a model in Settings → Voice Models first."); return }
        prepareVoice(model: model, reply: reply)
    }

    private func prepareVoice(model: LocalVoiceModel, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard setup == nil, processes.isEmpty, agents.isEmpty, realtime.isEmpty else {
                reply("The on-device voice is already being set up.")
                return
            }
            setup = Task.detached { [weak self] in
                let installer = VoiceInstaller(model: model) { [weak self] progress in
                    guard let data = try? JSONEncoder().encode(progress) else { return }
                    self?.client?.voiceSetupProgress(data)
                }
                var failure: String?
                do {
                    try await installer.prepare()
                } catch is CancellationError {
                    failure = nil
                } catch {
                    runnerLogger.error("Voice setup failed: \(error.localizedDescription, privacy: .public)")
                    failure = error.localizedDescription
                }
                if let self { self.queue.async { self.setup = nil } }
                reply(failure)
            }
        }
    }

    func cancelVoiceSetup() {
        queue.async { [self] in setup?.cancel() }
    }

    func terminateAll() {
        queue.async { [self] in
            invalidated = true
            setup?.cancel()
            for process in processes.values { process.terminate() }
            for agent in agents.values { Task { await agent.close() } }
            agents = [:]
            for session in realtime.values { Task { await session.close() } }
            realtime = [:]
        }
    }
}

/// One child process with line-delimited stdout and a retained tail of stderr for error messages.
final class RunnerProcess: @unchecked Sendable {
    private static let maximumLine = 16 * 1024 * 1024
    private static let stderrTail = 4 * 1024

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private let onLine: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32, String?) -> Void
    private var buffer = Data()
    private var discardingLongLine = false
    private var errorTail = Data()
    private var stdoutClosed = false
    private var exited = false
    private var reported = false

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
         onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32, String?) -> Void) {
        self.onLine = onLine
        self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.markStdoutClosed()
            } else {
                self?.consume(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.keepErrorTail(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.markExited()
            // A grandchild holding the pipe open mustn't keep the exit from being reported.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self?.report() }
        }
        try process.run()
    }

    func write(_ data: Data) {
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        try? stdin.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let identifier = process.processIdentifier
        // Holds this object too, since nothing else may by now and its handlers only hold it weakly.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { kill(identifier, SIGKILL) }
        }
    }

    private func consume(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                if discardingLongLine {
                    discardingLongLine = false
                } else if !line.isEmpty {
                    lines.append(line)
                }
            }
            // An oversized line can't be parsed anyway, so don't hold it in memory.
            if buffer.count > Self.maximumLine {
                buffer = Data()
                discardingLongLine = true
            }
            return lines
        }
        for line in lines { onLine(line) }
    }

    private func keepErrorTail(_ data: Data) {
        lock.withLock {
            errorTail.append(data)
            if errorTail.count > Self.stderrTail { errorTail = Data(errorTail.suffix(Self.stderrTail)) }
        }
    }

    private func markStdoutClosed() {
        let ready = lock.withLock { stdoutClosed = true; return exited }
        if ready { report() }
    }

    private func markExited() {
        let ready = lock.withLock { exited = true; return stdoutClosed }
        if ready { report() }
    }

    private func report() {
        let message: String? = lock.withLock {
            guard !reported else { return nil }
            reported = true
            let text = String(decoding: errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "" : text
        }
        guard let message else { return }
        onExit(process.terminationStatus, message.isEmpty ? nil : message)
    }
}
