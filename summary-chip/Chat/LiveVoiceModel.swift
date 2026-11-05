import Foundation
import LocalAgentKit
import RxAgentVoice
import RxAgentCore
import Observation
import OSLog
import SummaryKit
#if os(macOS)
import AppKit
#else
import AudioToolbox
#endif

@MainActor @Observable
final class LiveVoiceModel {
    private(set) var isActive = false
    private(set) var isConnecting = false
    private(set) var startedAt: Date?
    private(set) var level = 0.0
    private(set) var isSpeaking = false
    private(set) var inputLevel = 0.0
    private(set) var hasMicrophoneInput = false
    private(set) var microphoneWarning: String?
    private(set) var sentAudioSeconds = 0.0
    private(set) var providerHeardSpeech = false
    private let voiceLogger = Logger(subsystem: "com.rxlab.summary-chip", category: "VoiceChat")
    private var microphoneWatchdog: Task<Void, Never>?
    private(set) var latestResponse = ""
    /// A local agent's name, shown while it's the one answering.
    private(set) var localAgentName: String?
    /// What a local session is doing right now, when the usual status doesn't say enough.
    private(set) var activityDetail: String?
    /// A local agent or voice isn't ready, which is for the picker to resolve rather than an error.
    var needsLocalSetup = false
    #if os(macOS)
    private var appTools: VoiceAppTools?
    private var localSession: LocalLiveVoiceSession?
    private var localToolNames: [String: String] = [:]
    private var localToolEntries: [String: String] = [:]
    #endif
    var error: String?
    private(set) var currentToolID: String?
    private(set) var previousToolIDs = Set<String>()
    private var connection: (any VoiceConnection)?
    private var audio: LiveVoiceAudio?
    private var task: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var handledCalls = Set<String>()
    private var generation = UUID()
    private var assistantID: String?
    private var chat: ChatModel?
    private var api: SummaryAPIClient?
    private var context: ChatRequestBody?

    func start(api: SummaryAPIClient, chat: ChatModel, engine: LiveVoiceEngine = .chippy, language: LocalVoiceLanguage = .all[0]) {
        guard !isActive, !chat.isStreaming else { return }
        self.chat = chat
        self.api = api
        previousToolIDs = Set(chat.entries.flatMap(\.tools).map(\.id))
        isActive = true; isConnecting = true; error = nil; latestResponse = ""
        inputLevel = 0; hasMicrophoneInput = false; microphoneWarning = nil
        sentAudioSeconds = 0; providerHeardSpeech = false
        currentToolID = nil
        startedAt = nil; assistantID = nil; handledCalls = []
        let revision = UUID(); generation = revision
        localAgentName = nil; activityDetail = nil
        #if os(macOS)
        if let agent = engine.localAgent, engine != .codexRealtime {
            startLocal(agent: agent, language: language, api: api, chat: chat, revision: revision)
            return
        }
        #endif
        task = Task {
            do {
                guard await LiveVoiceAudio.requestPermission() else {
                    throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in Settings to start voice chat."])
                }
                try Task.checkCancellation()
                // Started before connecting, so it also covers a setup step that never returns.
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self, self.generation == revision, self.isConnecting else { return }
                    self.fail("Voice connection timed out. Please try again.")
                }
                defer { timeout.cancel() }
                let context = await chat.voiceContext()
                self.context = context
                let connection = try await connect(engine: engine, api: api, context: context, language: language)
                guard generation == revision, !Task.isCancelled else { await connection.close(); return }
                self.connection = connection
                for await event in connection.events {
                    guard generation == revision, !Task.isCancelled else { return }
                    try await receiveSDK(event, revision: revision)
                }
                if generation == revision { stop() }

            } catch {
                if generation == revision, !Task.isCancelled {
                    let failure = error as NSError
                    let closeCode = 0
                    voiceLogger.error("Voice failed: domain=\(failure.domain, privacy: .public) code=\(failure.code) WebSocketClose=\(closeCode) message=\(failure.localizedDescription, privacy: .public)")
                    fail("\(failure.localizedDescription) (\(failure.domain) \(failure.code), socket close \(closeCode))")
                }
            }
        }
    }

    func stop() {
        guard isActive else { return }
        generation = UUID()
        task?.cancel(); task = nil
        captureTask?.cancel(); captureTask = nil
        microphoneWatchdog?.cancel(); microphoneWatchdog = nil
        inputLevel = 0; hasMicrophoneInput = false; microphoneWarning = nil
        for task in toolTasks.values { task.cancel() }
        toolTasks = [:]
        let oldConnection = connection; connection = nil
        Task { await oldConnection?.close() }
        audio?.stop(); audio = nil
        #if os(macOS)
        appTools?.stop(); appTools = nil
        localSession?.stopSynchronously(); localSession = nil
        localToolNames = [:]; localToolEntries = [:]
        #endif
        activityDetail = nil
        chat?.finishVoice()
        currentToolID = nil
        isActive = false; isConnecting = false; level = 0; isSpeaking = false
    }

    private func fail(_ message: String) {
        voiceLogger.error("Stopping voice: \(message, privacy: .public)")
        stop(); error = message
    }

    private func connect(engine: LiveVoiceEngine, api: SummaryAPIClient, context: ChatRequestBody,
                         language: LocalVoiceLanguage) async throws -> any VoiceConnection {
        #if os(macOS)
        if engine == .codexRealtime {
            localAgentName = "Codex Realtime"
            let realtime = CodexSDKVoiceConnection()
            realtime.onTool = { [weak self] in self?.receiveLocal($0) }
            self.connection = realtime
            guard let chat else { throw VoiceError.invalidState }
            let bridge = VoiceAppTools(chat: chat)
            appTools = bridge
            let endpoint = try await bridge.start()
            var launch = LocalAgentLaunch(kind: .codex, mcpURL: api.mcpEndpoint,
                mcpToken: try await LocalAgentCredentials.token(api: api),
                instructions: LocalAgentInstructions.build(agent: .codex, language: language, context: context),
                realtimeVoice: UserDefaults.standard.string(forKey: LiveVoiceSettings.realtimeVoiceKey).flatMap { LiveVoiceSettings.realtimeVoices.contains($0) ? $0 : nil })
            launch.appToolsURL = endpoint
            launch.appToolsToken = bridge.token
            try await realtime.start(launch)
            return realtime
        }
        #endif
        return try await geminiConnection(api: api, context: context)
    }

    private func geminiConnection(api: SummaryAPIClient, context: ChatRequestBody) async throws -> any VoiceConnection {
        let session = try await api.createLiveChatSession(context: context)
        try Task.checkCancellation()
        let config = try JSONDecoder().decode(RxAgentCore.JSONValue.self, from: JSONEncoder().encode(session.config))
        let info = GeminiVoiceConnectionInfo(url: session.url, protocols: session.protocols ?? [], config: config)
        return try await GeminiVoiceEngine { info }.connect(.init())
    }

    private func receiveSDK(_ event: VoiceEngineEvent, revision: UUID) async throws {
        switch event {
        case .ready:
            #if os(macOS)
            if let realtime = connection as? CodexSDKVoiceConnection {
                startRealtimeAudio(realtime, revision: revision)
                return
            }
            #endif
            try startCapture(revision: revision) { [weak self] data in
                guard let connection = self?.connection else { return }
                try await connection.send(audio: .init(data: data, format: .init(sampleRate: 16_000)))
            }
        case .userSpeechStarted:
            currentToolID = nil; audio?.interrupt(); assistantID = nil
        case .assistantAudio(_, let frame):
            guard frame.format == VoicePCMFormat() else { throw VoiceError.invalidAudio }
            try audio?.play(frame.data)
        case .assistantText(_, let delta): appendAssistant(delta)
        case .userTranscript(let id, let text, let final):
            if final { providerHeardSpeech = true; currentToolID = nil; chat?.appendVoiceUser(text, id: id) }
        case .assistantDone: assistantID = nil; chat?.finishVoice()
        case .toolCallRequested(let id, let name, let input):
            let arguments = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
            receiveToolCall(["callId": id, "name": name, "arguments": arguments], revision: revision)
        case .closed: stop()
        case .failed(let error):
            let message = error.localizedDescription
            if localAgentName == "Codex Realtime" {
                fail("Codex Realtime could not connect. You can select Codex · Local Speech in Voice Agent to use on-device speech instead.\n\n" + message)
            } else { fail(message) }
        case .userSpeechStopped, .toolActivity: break
        }
    }

    private func startCapture(revision: UUID, timeLimit: TimeInterval? = 600, deliver: @escaping (Data) async throws -> Void) throws {
        guard isConnecting else { return }
        let audio = LiveVoiceAudio()
        self.audio = audio
        audio.onLevel = { [weak self] in self?.level = $0 }
        audio.onPlaybackChanged = { [weak self] in self?.isSpeaking = $0 }
        audio.onFailure = { [weak self] in
            guard let self, self.generation == revision else { return }
            self.fail("The audio device changed. Start voice chat again to reconnect.")
        }
        voiceLogger.info("Starting microphone and speaker")
        let stream = try audio.start()
        voiceLogger.info("Microphone and speaker ready")
        isConnecting = false; startedAt = Date()
        playReadySound()
        startMicrophoneWatchdog(revision: revision)
        captureTask = Task { [weak self] in
            do {
                for await data in stream {
                    guard let self, !Task.isCancelled, self.generation == revision else { return }
                    if let timeLimit, let startedAt = self.startedAt, Date().timeIntervalSince(startedAt) >= timeLimit {
                        self.fail("Voice session reached 10 minutes. Start a new session to continue."); return
                    }
                    var energy = 0.0
                    for index in stride(from: 0, to: data.count, by: 2) {
                        let sample = Double(Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)) / 32768
                        energy += sample * sample
                    }
                    // Receiving zero-filled buffers does not establish microphone input.
                    if energy > 0 {
                        self.hasMicrophoneInput = true
                        self.microphoneWarning = nil
                    }
                    let rms = sqrt(energy / Double(max(1, data.count / 2)))
                    // A linear amplitude meter hides quiet but valid microphone audio.
                    self.inputLevel = rms > 0 ? min(1, max(0, (20 * log10(rms) + 60) / 60)) : 0
                    try await deliver(data)
                    let previousSeconds = Int(self.sentAudioSeconds)
                    self.sentAudioSeconds += Double(data.count) / 32000
                    if Int(self.sentAudioSeconds) / 5 > previousSeconds / 5 {
                        self.voiceLogger.info("Sent PCM seconds=\(self.sentAudioSeconds) inputRMS=\(rms)")
                    }
                }
            } catch { if let self, self.generation == revision, !Task.isCancelled { self.fail(error.localizedDescription) } }
        }
    }

    /// Called only after the transport and audio are ready, once per connection.
    private func playReadySound() {
        #if os(macOS)
        NSSound(named: "Glass")?.play()
        #else
        AudioServicesPlaySystemSound(1057)
        #endif
    }

    private func startMicrophoneWatchdog(revision: UUID) {
        microphoneWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == revision,
                  !self.hasMicrophoneInput else { return }
            self.microphoneWarning = "No microphone sound detected. Check your system sound input, input volume, and microphone access."
        }
    }

    private func receiveToolCall(_ event: [String: Any], revision: UUID) {
        guard let id = event["callId"] as? String, handledCalls.insert(id).inserted else { return }
        currentToolID = id
        let name = event["name"] as? String ?? ""
        let arguments = Data((event["arguments"] as? String ?? "{}").utf8)
        let input = (try? JSONDecoder().decode(SummaryKit.JSONValue.self, from: arguments)) ?? .null
        let entryID = chat?.beginVoiceAssistant()
        if let entryID { chat?.recordVoiceTool(.toolInputAvailable(toolCallId: id, toolName: name, input: input), entryID: entryID) }
        toolTasks[id] = Task { [weak self] in
            guard let self, let api = self.api, let context = self.context else { return }
            defer {
                if self.generation == revision {
                    self.toolTasks[id] = nil
                    if self.toolTasks.isEmpty { self.audio?.setToolActivity(false) }
                }
            }
            let output: String
            do {
                // Execute received calls immediately; narration playback must not gate work.
                try Task.checkCancellation()
                guard self.generation == revision else { return }
                let result = try await api.executeLiveChatTool(context: context, name: name, callID: id, input: input)
                try Task.checkCancellation()
                guard self.generation == revision else { return }
                if let entryID { self.chat?.recordVoiceTool(.toolOutputAvailable(toolCallId: id, output: result), entryID: entryID) }
                output = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            } catch {
                guard self.generation == revision, !Task.isCancelled else { return }
                output = "Tool failed: " + error.localizedDescription
                if let entryID { self.chat?.recordVoiceTool(.toolOutputError(toolCallId: id, errorText: output), entryID: entryID) }
            }
            guard self.generation == revision, !Task.isCancelled else { return }
            do {
                try await self.connection?.submitToolResult(callID: id, result: .text(output))
            } catch { self.fail(error.localizedDescription) }
        }
        audio?.setToolActivity(true)
    }

    private func appendAssistant(_ delta: String) {
        guard !delta.isEmpty else { return }
        if assistantID == nil {
            assistantID = chat?.beginVoiceAssistant()
            latestResponse = ""
        }
        latestResponse += delta
        if let assistantID { chat?.setVoiceText(assistantID, text: latestResponse) }
    }
}

#if os(macOS)
// MARK: - Local agents

extension LiveVoiceModel {
    /// WebRTC runs the microphone and speaker itself, so this only follows along for the UI.
    private func startRealtimeAudio(_ realtime: CodexSDKVoiceConnection, revision: UUID) {
        guard isConnecting else { return }
        isConnecting = false; startedAt = Date()
        playReadySound()
        startMicrophoneWatchdog(revision: revision)
        realtime.onLevels = { [weak self] input, output in
            guard let self, self.generation == revision else { return }
            if input > 0 { self.hasMicrophoneInput = true; self.microphoneWarning = nil }
            // Same scale as captured audio: a linear meter hides quiet but valid speech.
            self.inputLevel = input > 0 ? min(1, max(0, (20 * log10(input) + 60) / 60)) : 0
            self.level = output
            self.isSpeaking = output > 0.01
        }
        captureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, self.generation == revision else { return }
            self.fail("Voice session reached 10 minutes. Start a new session to continue.")
        }
    }

    private func startLocal(agent: LocalAgentKind, language: LocalVoiceLanguage, api: SummaryAPIClient, chat: ChatModel, revision: UUID) {
        localAgentName = agent.displayName
        task = Task {
            let session = LocalLiveVoiceSession(agent: agent, language: language)
            localSession = session
            session.onEvent = { [weak self] in self?.receiveLocal($0) }
            session.onUtterance = { [weak self] text in
                guard let self else { return }
                self.providerHeardSpeech = true
                self.currentToolID = nil
                self.assistantID = nil
                self.latestResponse = ""
                self.activityDetail = String(localized: "\(agent.displayName) is working…")
                self.audio?.setToolActivity(true)
                self.chat?.finishVoice()
                self.chat?.appendVoiceUser(text)
            }
            session.onFailure = { [weak self] message in
                guard let self, self.generation == revision else { return }
                self.fail(message)
            }
            do {
                guard await LiveVoiceAudio.requestPermission() else {
                    throw LocalVoiceFailure(String(localized: "Allow microphone access in Settings to start voice chat."))
                }
                let context = await chat.voiceContext()
                try await session.prepare(api: api, context: context) { [weak self] in self?.activityDetail = $0 }
                guard generation == revision, !Task.isCancelled else { return }
                // There's no cloud session to pay for here, so no time limit either.
                try startCapture(revision: revision, timeLimit: nil) { data in try await session.receive(pcm: data) }
                if let audio { session.attach(audio) }
                activityDetail = nil
            } catch is LocalLiveVoiceSession.SetupRequired {
                guard generation == revision else { return }
                stop()
                needsLocalSetup = true
            } catch {
                guard generation == revision, !Task.isCancelled, !(error is CancellationError) else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func receiveLocal(_ event: LocalAgentEvent) {
        switch event {
        case .sessionStarted, .textEnded:
            break
        case .textDelta(let delta):
            activityDetail = nil
            // The agent is answering now, so its reply takes over from the cue.
            audio?.setToolActivity(false)
            appendAssistant(delta)
        case .toolStarted(let id, let name, let input):
            let toolName = LocalToolOutput.chatToolName(name)
            let entryID = chat?.beginVoiceAssistant()
            // Text after this tool belongs in a new bubble, so the transcript keeps its order.
            assistantID = nil
            currentToolID = id
            localToolNames[id] = toolName
            localToolEntries[id] = entryID
            let value = (try? JSONDecoder().decode(SummaryKit.JSONValue.self, from: input)) ?? .null
            if let entryID { chat?.recordVoiceTool(.toolInputAvailable(toolCallId: id, toolName: toolName, input: value), entryID: entryID) }
            audio?.setToolActivity(true)
        case .toolFinished(let id, let output, let isError):
            finishLocalTool(id: id, output: output, isError: isError)
        case .turnFinished:
            assistantID = nil
            activityDetail = nil
            chat?.finishVoice()
            audio?.setToolActivity(false)
        case .failed(let message):
            fail(message)
        }
    }

    private func finishLocalTool(id: String, output: String, isError: Bool) {
        guard let entryID = localToolEntries.removeValue(forKey: id) else { return }
        let name = localToolNames.removeValue(forKey: id)
        if isError {
            chat?.recordVoiceTool(.toolOutputError(toolCallId: id, errorText: output), entryID: entryID)
        } else {
            let data = LocalToolOutput.chatOutput(toolName: name ?? "", output: output)
            let value = (try? JSONDecoder().decode(SummaryKit.JSONValue.self, from: data)) ?? .object(["text": .string(output)])
            chat?.recordVoiceTool(.toolOutputAvailable(toolCallId: id, output: value), entryID: entryID)
            // The cloud agent reports edits in its own output format, which these tools don't use.
            if name.map(LocalToolOutput.changesOpenDocument) == true {
                chat?.onTripUpdated?()
                chat?.onGraphUpdated?()
            }
        }
        // The cue keeps going after a tool returns. Local tools often finish while the "let me check"
        // sentence is still playing, and stopping here would mean the cue never gets heard at all.
    }

}
#endif
