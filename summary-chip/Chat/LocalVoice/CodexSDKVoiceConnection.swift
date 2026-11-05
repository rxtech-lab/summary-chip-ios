#if os(macOS)
import AVFoundation
import Foundation
import LocalAgentKit
import RxAgentCore
import RxAgentVoice
@preconcurrency import WebRTC

/// Codex Realtime over WebRTC, the one transport Codex accepts with a ChatGPT sign-in. Codex runs in the
/// XPC runner and handles signaling; microphone and speaker audio flow directly through `CodexRealtimePeer`.
@MainActor
final class CodexSDKVoiceConnection: VoiceConnection {
    nonisolated let inputFormat = VoicePCMFormat()
    nonisolated let events: AsyncStream<VoiceEngineEvent>
    /// Linear levels from 0 to 1, reported a few times a second while connected.
    var onLevels: ((_ input: Double, _ output: Double) -> Void)?
    /// Codex runs its tools itself, so this only reports them.
    var onTool: ((LocalAgentEvent) -> Void)?
    private let output: AsyncStream<VoiceEngineEvent>.Continuation
    private let id = UUID().uuidString
    private var peer: CodexRealtimePeer?
    private var levelPolling: Task<Void, Never>?
    private let toolCue = RealtimeToolCue()
    private var isMidResponse = false
    private var isReady = false
    private var closed = false

    init() { (events, output) = AsyncStream.makeStream() }

    func start(_ launch: LocalAgentLaunch) async throws {
        let peer = CodexRealtimePeer { [weak self] state in
            Task { @MainActor in self?.peerChanged(state) }
        }
        self.peer = peer
        let offer = try await peer.makeOffer()
        guard !closed else { throw CancellationError() }
        try await LocalAgentRunnerClient.shared.startRealtime(launch, offer: offer, id: id, handler: .init(onLine: { [weak self] data in
            self?.receive(data)
        }, onExit: { [weak self] _, message in
            self?.finish(.failed(.transport(message ?? "Codex disconnected.")))
        }))
        if closed { LocalAgentRunnerClient.shared.terminate(id: id); throw CancellationError() }
    }

    private func receive(_ data: Data) {
        guard !closed, let packet = try? JSONDecoder().decode(LocalRealtimeEvent.self, from: data) else { return }
        switch packet.kind {
        case .answer:
            guard let peer, let answer = packet.text else { return }
            Task { [weak self] in
                do { try await peer.accept(answer: answer) }
                catch { self?.finish(.failed(.transport(error.localizedDescription))) }
            }
        case .assistantDelta:
            // Codex starts each response with a space, since deltas are joined as they arrive.
            let delta = packet.text ?? ""
            output.yield(.assistantText(itemID: nil, delta: isMidResponse ? delta : String(delta.drop(while: \.isWhitespace))))
            isMidResponse = true
        case .assistantDone:
            isMidResponse = false
            output.yield(.assistantDone(itemID: nil))
        case .userTranscript:
            let text = (packet.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { output.yield(.userTranscript(itemID: UUID().uuidString, text: text, isFinal: true)) }
        case .error:
            finish(.failed(.transport(packet.text ?? "Codex voice failed.")))
        case .closed:
            finish(.closed(reason: nil))
        case .tool:
            guard let tool = packet.tool else { return }
            if case .toolStarted = tool { toolCue.start() }
            onTool?(tool)
        case .turnEnded:
            toolCue.stop()
        }
    }

    private func peerChanged(_ state: CodexRealtimePeer.State) {
        guard !closed else { return }
        switch state {
        case .connected:
            guard !isReady else { return }
            isReady = true
            output.yield(.ready)
            pollLevels()
        case .failed:
            finish(.failed(.transport("The audio connection to Codex was lost.")))
        }
    }

    private func pollLevels() {
        guard let peer else { return }
        levelPolling = Task { [weak self] in
            while !Task.isCancelled {
                let levels = await peer.levels()
                guard !Task.isCancelled else { return }
                self?.toolCue.isModelSpeaking = levels.output > 0.01
                self?.onLevels?(levels.input, levels.output)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Reports how the session ended, then shuts it down.
    private func finish(_ event: VoiceEngineEvent) {
        guard !closed else { return }
        output.yield(event)
        shutDown()
    }

    private func shutDown() {
        closed = true
        levelPolling?.cancel(); levelPolling = nil
        toolCue.stop()
        LocalAgentRunnerClient.shared.terminate(id: id)
        peer?.close(); peer = nil
        output.finish()
    }

    // The peer connection captures the microphone itself.
    func send(audio: VoiceAudioFrame) async throws { throw VoiceError.invalidState }
    func send(text: String) async throws { throw VoiceError.unavailable("Use the microphone for Codex realtime.") }
    // The server notices the user talking over a response and stops it.
    func interrupt(_ interruption: VoiceInterruption) async throws {}
    func submitToolResult(callID: String, result: AgentToolResult) async throws { throw VoiceError.unavailable("Codex owns its tools.") }
    func close() async { if !closed { shutDown() } }
}

/// The sound that says tools are running. WebRTC owns the session's audio, so this needs an output
/// of its own. It never touches the engine's input node, which leaves the microphone to WebRTC.
@MainActor
private final class RealtimeToolCue {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var loop: Task<Void, Never>?
    /// The cue waits while the model talks, so the two don't overlap.
    var isModelSpeaking = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let played = self?.playIfQuiet() ?? false
                try? await Task.sleep(for: .milliseconds(played ? 1800 : 100))
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        player.stop()
        engine.stop()
    }

    private func playIfQuiet() -> Bool {
        guard !isModelSpeaking, let buffer = LiveVoiceAudio.toolCueBuffer() else { return false }
        do {
            // A change of audio device stops the engine, so this also recovers from that.
            if !engine.isRunning { try engine.start() }
        } catch {
            return false
        }
        player.scheduleBuffer(buffer)
        player.play()
        return true
    }
}

/// WebRTC calls back on its own threads, so nothing here may inherit the main actor.
/// `RTCPeerConnection` is safe to call from any thread.
nonisolated final class CodexRealtimePeer: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    enum State: Sendable { case connected, failed }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let onChange: @Sendable (State) -> Void
    private var connection: RTCPeerConnection?
    /// OpenAI's sessions expect this channel in the offer. Codex reads events through its own connection.
    private var events: RTCDataChannel?

    init(onChange: @escaping @Sendable (State) -> Void) { self.onChange = onChange }

    /// Codex takes a single offer with no trickling, so this waits for ICE candidates to be included.
    func makeOffer() async throws -> String {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw VoiceError.unavailable("Couldn't set up the audio connection.")
        }
        self.connection = connection
        let source = Self.factory.audioSource(with: constraints)
        connection.add(Self.factory.audioTrack(with: source, trackId: "microphone"), streamIds: ["chippy"])
        events = connection.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { @Sendable description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? VoiceError.invalidState) }
            }
        }
        try await apply(offer, setter: connection.setLocalDescription)
        let deadline = ContinuousClock.now + .seconds(3)
        while connection.iceGatheringState != .complete, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let sdp = connection.localDescription?.sdp else { throw VoiceError.invalidState }
        return sdp
    }

    func accept(answer: String) async throws {
        guard let connection else { throw VoiceError.invalidState }
        try await apply(RTCSessionDescription(type: .answer, sdp: answer), setter: connection.setRemoteDescription)
    }

    private func apply(_ description: RTCSessionDescription,
                       setter: (RTCSessionDescription, @escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setter(description) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func levels() async -> (input: Double, output: Double) {
        guard let connection else { return (0, 0) }
        return await withCheckedContinuation { continuation in
            connection.statistics { @Sendable report in
                var levels = (input: 0.0, output: 0.0)
                for statistic in report.statistics.values {
                    let level = (statistic.values["audioLevel"] as? NSNumber)?.doubleValue ?? 0
                    switch statistic.type {
                    case "media-source": levels.input = max(levels.input, level)
                    case "inbound-rtp": levels.output = max(levels.output, level)
                    default: break
                    }
                }
                continuation.resume(returning: levels)
            }
        }
    }

    func close() {
        events?.close(); events = nil
        connection?.close(); connection = nil
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        switch state {
        case .connected: onChange(.connected)
        case .failed: onChange(.failed)
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
#endif

#if os(macOS)
@preconcurrency import Network
import SummaryKit

/// Session-scoped MCP endpoint. Reads selection on demand without creating a conversation turn.
@MainActor
final class VoiceAppTools {
    let token = UUID().uuidString
    private weak var chat: ChatModel?
    private var listener: NWListener?
    private var startup: CheckedContinuation<URL, Error>?
    private var clients: [UUID: NWConnection] = [:]

    init(chat: ChatModel) { self.chat = chat }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let id = UUID()
                self.clients[id] = connection
                connection.start(queue: .main)
                self.read(connection, id: id, buffer: Data())
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    self?.clients.removeValue(forKey: id)?.cancel()
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.startup = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let continuation = self.startup else { return }
                    switch state {
                    case .ready:
                        self.startup = nil
                        continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/mcp")!)
                    case .failed(let error):
                        self.startup = nil; continuation.resume(throwing: error)
                    case .cancelled:
                        self.startup = nil; continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        startup?.resume(throwing: CancellationError()); startup = nil
        listener?.cancel(); listener = nil
        for connection in clients.values { connection.cancel() }
        clients = [:]
    }

    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                var buffer = buffer
                buffer.append(data ?? Data())
                guard buffer.count <= 262_144, error == nil else { self.reply(connection, id: id, status: 400); return }
                if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
                    let lines = header.components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                    }
                    guard headers["authorization"] == "Bearer \(self.token)", headers["origin"] == nil else {
                        self.reply(connection, id: id, status: 403); return
                    }
                    guard lines.first == "POST /mcp HTTP/1.1", let length = Int(headers["content-length"] ?? ""), length >= 0, length <= 200_000 else {
                        self.reply(connection, id: id, status: 400); return
                    }
                    if buffer.count - boundary.upperBound >= length {
                        let body = buffer.subdata(in: boundary.upperBound..<(boundary.upperBound + length))
                        let response = self.handle(body)
                        self.reply(connection, id: id, status: response == nil ? 202 : 200, body: response)
                        return
                    }
                }
                if complete { self.reply(connection, id: id, status: 400) }
                else { self.read(connection, id: id, buffer: buffer) }
            }
        }
    }

    private func reply(_ connection: NWConnection, id: UUID, status: Int, body: Data? = nil) {
        let body = body ?? Data()
        var response = Data("HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.clients.removeValue(forKey: id) }
        })
    }

    private func handle(_ body: Data) -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let id = request["id"] else { return nil }
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch request["method"] as? String {
        case "initialize":
            response["result"] = ["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "chippy_ui", "version": "1.0"]]
        case "ping": response["result"] = [:] as [String: String]
        case "tools/list":
            response["result"] = ["tools": [
                ["name": "get_user_selection", "description": "Read the user's CURRENT graph and selected nodes and edges. Call whenever they refer to this node or the selection; it can change during voice chat.", "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]],
                ["name": "open_node_detail", "description": "Open an existing node's full native detail view, including its properties, images and saved view. Choose presentation window for a separate window or popover for details anchored to a visible node. Defaults to popover. Use get_user_selection to resolve the selected node. Does not edit the graph.", "inputSchema": ["type": "object", "properties": ["nodeId": ["type": "string"], "presentation": ["type": "string", "enum": ["window", "popover"]]], "required": ["nodeId"], "additionalProperties": false]],
                ["name": "center_graph_nodes", "description": "Center and frame one or more existing visible nodes in the current graph. Pass nodeIds; read get_user_selection first for selected nodes. Pauses auto-rotation. Does not edit the graph or change selection.", "inputSchema": ["type": "object", "properties": ["nodeIds": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 500]], "required": ["nodeIds"], "additionalProperties": false]],
                ["name": "show_node_tooltip", "description": "Show a temporary native tooltip/popover above an existing node in the current graph. Does not edit the graph. Use this instead of computer use.", "inputSchema": ["type": "object", "properties": ["nodeId": ["type": "string"], "title": ["type": "string"], "text": ["type": "string"]], "required": ["nodeId", "title", "text"], "additionalProperties": false]]
            ]]
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            do {
                let payload = try call(params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:])
                let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
                response["result"] = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
            } catch {
                response["result"] = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default: response["error"] = ["code": -32601, "message": "Method not found"]
        }
        return try? JSONSerialization.data(withJSONObject: response)
    }

    private func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let chat else { throw VoiceError.unavailable("The chat is closed.") }
        switch name {
        case "get_user_selection":
            let nodes = chat.graphDocument?.nodes.filter { chat.graphElements.contains(.node($0.id)) } ?? []
            let edges = chat.graphDocument?.edges.filter { chat.graphElements.contains(.edge($0.id)) } ?? []
            return ["graphId": chat.graph?.id as Any? ?? NSNull(),
                    "nodes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(nodes)),
                    "edges": try JSONSerialization.jsonObject(with: JSONEncoder().encode(edges))]
        case "open_node_detail":
            let presentation = arguments["presentation"] as? String ?? "popover"
            guard let id = arguments["nodeId"] as? String,
                  arguments["presentation"] == nil || arguments["presentation"] is String,
                  ["window", "popover"].contains(presentation),
                  let open = chat.onGraphOpenNode, open(id, presentation) else {
                throw VoiceError.unavailable("Supply an existing nodeId and presentation window or popover. A popover requires a visible, laid-out node in the open graph.")
            }
            return ["opened": true, "nodeId": id, "presentation": presentation]
        case "center_graph_nodes":
            guard let ids = arguments["nodeIds"] as? [String], !ids.isEmpty, ids.count <= 500,
                  ids.allSatisfy({ id in chat.graphDocument?.nodes.contains { $0.id == id } == true }),
                  let center = chat.onGraphCenter, center(Array(Set(ids))) else {
                throw VoiceError.unavailable("Supply 1–500 existing visible node IDs in an open, laid-out graph.")
            }
            return ["centered": true, "nodeIds": ids]
        case "show_node_tooltip":
            guard let node = arguments["nodeId"] as? String,
                  chat.graphDocument?.nodes.contains(where: { $0.id == node }) == true,
                  let title = arguments["title"] as? String, !title.isEmpty, title.count <= 200,
                  let text = arguments["text"] as? String, !text.isEmpty, text.count <= 10_000,
                  let display = chat.onGraphUI else { throw VoiceError.unavailable("Supply an existing nodeId, title (1–200 characters), and text (1–10000 characters) in an open graph.") }
            let payload: [String: Any] = ["nodeId": node, "title": title, "currency": "USD", "spec": ["root": "body", "elements": ["body": ["type": "Text", "props": ["text": text]]]]]
            display(try JSONDecoder().decode(ChatRenderedUI.self, from: JSONSerialization.data(withJSONObject: payload)))
            return ["shown": true, "nodeId": node]
        default: throw VoiceError.unavailable("Unknown app tool.")
        }
    }
}
#endif
