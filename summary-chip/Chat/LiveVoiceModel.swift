import Foundation
import Observation
import OSLog
import SummaryKit

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
    var error: String?
    private(set) var currentToolID: String?
    private(set) var previousToolIDs = Set<String>()
    private var socket: URLSessionWebSocketTask?
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

    func start(api: SummaryAPIClient, chat: ChatModel) {
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
        task = Task {
            do {
                guard await LiveVoiceAudio.requestPermission() else {
                    throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow microphone access in Settings to start voice chat."])
                }
                try Task.checkCancellation()
                let context = await chat.voiceContext()
                self.context = context
                let session = try await api.createLiveChatSession(context: context)
                try Task.checkCancellation()
                guard generation == revision else { return }
                let socket = URLSession.shared.webSocketTask(with: session.url, protocols: session.protocols ?? [])
                socket.maximumMessageSize = 2 * 1024 * 1024
                self.socket = socket
                socket.resume()
                let config = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.config))
                try await send(["type": "session-update", "config": config])
                // A bounded timeout also covers a connection that never acknowledges setup.
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, let self, self.generation == revision, self.isConnecting else { return }
                    self.fail("Voice connection timed out. Please try again.")
                }
                defer { timeout.cancel() }
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard generation == revision else { return }
                    let bytes: Data
                    switch message {
                    case .data(let value): bytes = value
                    case .string(let value): bytes = Data(value.utf8)
                    @unknown default: continue
                    }
                    let raw = try JSONSerialization.jsonObject(with: bytes)
                    let events = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
                    for event in events { try await receive(event, revision: revision) }
                }
            } catch {
                if generation == revision, !Task.isCancelled {
                    let failure = error as NSError
                    let closeCode = self.socket?.closeCode.rawValue ?? 0
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
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        audio?.stop(); audio = nil
        chat?.finishVoice()
        currentToolID = nil
        isActive = false; isConnecting = false; level = 0; isSpeaking = false
    }

    private func fail(_ message: String) {
        voiceLogger.error("Stopping voice: \(message, privacy: .public)")
        stop(); error = message
    }

    private func send(_ value: [String: Any]) async throws {
        guard let socket else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ event: [String: Any], revision: UUID) async throws {
        let type = event["type"] as? String ?? ""
        if type != "custom" { voiceLogger.debug("Received voice event: \(type, privacy: .public)") }
        switch type {
        case "session-created", "session-updated", "session-started":
            try startCapture(revision: revision)
        case "speech-started":
            currentToolID = nil
            audio?.interrupt()
            assistantID = nil
        case "response-created": assistantID = nil
        case "audio-delta", "audio-chunk":
            if let delta = event["delta"] as? String, let data = Data(base64Encoded: delta) { try audio?.play(data) }
        case "audio-transcript-delta", "text-delta":
            appendAssistant(event["delta"] as? String ?? "")
        case "audio-transcript-done":
            if let text = event["transcript"] as? String {
                if assistantID == nil { appendAssistant(text) }
                else if let assistantID { latestResponse = text; chat?.setVoiceText(assistantID, text: text) }
            }
        case "input-transcription-completed":
            currentToolID = nil
            providerHeardSpeech = true
            if let text = event["transcript"] as? String { chat?.appendVoiceUser(text, id: event["itemId"] as? String) }
        case "response-done": assistantID = nil; chat?.finishVoice()
        case "function-call-arguments-done":
            receiveToolCall(event, revision: revision)
        case "custom":
            receiveCustomEvent(event)
        case "session-closed": stop()
        case "error": fail(event["message"] as? String ?? "Voice connection failed.")
        default: break
        }
    }

    private func startCapture(revision: UUID) throws {
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
        microphoneWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.generation == revision,
                  !self.hasMicrophoneInput else { return }
            self.microphoneWarning = "No microphone sound detected. Check your system sound input, input volume, and microphone access."
        }
        captureTask = Task { [weak self] in
            do {
                for await data in stream {
                    guard let self, !Task.isCancelled, self.generation == revision else { return }
                    if let startedAt = self.startedAt, Date().timeIntervalSince(startedAt) >= 600 {
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
                    try await self.send(["type": "input-audio-append", "audio": data.base64EncodedString()])
                    let previousSeconds = Int(self.sentAudioSeconds)
                    self.sentAudioSeconds += Double(data.count) / 32000
                    if Int(self.sentAudioSeconds) / 5 > previousSeconds / 5 {
                        self.voiceLogger.info("Sent PCM seconds=\(self.sentAudioSeconds) inputRMS=\(rms)")
                    }
                }
            } catch { if let self, self.generation == revision, !Task.isCancelled { self.fail(error.localizedDescription) } }
        }
    }

    private func receiveToolCall(_ event: [String: Any], revision: UUID) {
        guard let id = event["callId"] as? String, handledCalls.insert(id).inserted else { return }
        currentToolID = id
        let name = event["name"] as? String ?? ""
        let arguments = Data((event["arguments"] as? String ?? "{}").utf8)
        let input = (try? JSONDecoder().decode(JSONValue.self, from: arguments)) ?? .null
        let entryID = chat?.beginVoiceAssistant()
        if let entryID { chat?.recordVoiceTool(.toolInputAvailable(toolCallId: id, toolName: name, input: input), entryID: entryID) }
        toolTasks[id] = Task { [weak self] in
            guard let self, let api = self.api, let context = self.context else { return }
            let output: String
            do {
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
                try await self.send(["type": "conversation-item-create", "item": ["type": "function-call-output", "callId": id, "name": name, "output": output]])
            } catch { self.fail(error.localizedDescription) }
            self.toolTasks[id] = nil
        }
    }

    private func receiveCustomEvent(_ event: [String: Any]) {
        let raw = event["raw"] as? [String: Any]
        if let cancellation = raw?["toolCallCancellation"] as? [String: Any], let ids = cancellation["ids"] as? [String] {
            for id in ids {
                toolTasks[id]?.cancel(); toolTasks[id] = nil
                if currentToolID == id { currentToolID = nil }
            }
        }
        if let content = raw?["serverContent"] as? [String: Any], content["interrupted"] as? Bool == true { audio?.interrupt(); assistantID = nil; currentToolID = nil }
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
