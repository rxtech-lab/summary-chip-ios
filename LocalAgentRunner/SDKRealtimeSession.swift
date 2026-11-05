import Foundation
import LocalAgentKit
import RxAgentClients
import RxAgentCore

/// Runs Codex's side of a realtime session. The app owns the WebRTC connection and its audio,
/// so only signaling, transcripts and tool activity pass through here.
actor SDKRealtimeSession {
    private var session: CodexRealtimeSession?
    private var reader: Task<Void, Never>?
    private var closed = false

    func start(launch: LocalAgentLaunch, offer: String, binary: String, environment: [String: String], directory: URL,
               emit: @escaping @Sendable (Data) -> Void) async throws {
        let arguments = LocalAgentCommand.arguments(for: launch)
        let overrides = ["features.computer_use=false", "features.browser_use=false", "features.browser_use_external=false", "features.apps=false"] + stride(from: 4, to: arguments.count, by: 2).map { arguments[$0] }
        let client = CodexClient(binaryPath: binary, approvalPolicy: .never, sandbox: .readOnly, configOverrides: overrides,
                                 environment: environment.merging(LocalAgentCommand.environment(for: launch)) { _, new in new })
        let session = try await client.startRealtime(workingDirectory: directory, instructions: launch.instructions,
                                                     voice: launch.realtimeVoice, transport: .webRTC(offer: offer))
        guard !closed else { await session.close(); throw CancellationError() }
        self.session = session
        reader = Task {
            for await event in session.events {
                guard !Task.isCancelled else { return }
                if let packet = Self.packet(for: event) { Self.send(packet, emit) }
            }
            // Codex exiting ends the stream without saying so, and the app must not keep a dead session.
            if !Task.isCancelled { Self.send(.init(kind: .closed), emit) }
        }
    }

    func close() async {
        closed = true
        reader?.cancel(); reader = nil
        await session?.close(); session = nil
    }

    private static func send(_ packet: LocalRealtimeEvent, _ emit: @Sendable (Data) -> Void) {
        if let data = try? JSONEncoder().encode(packet) { emit(data) }
    }

    private static func packet(for event: CodexRealtimeSession.Event) -> LocalRealtimeEvent? {
        let params = event.params
        let isUser = params["role"]?.stringValue == "user"
        switch event.method {
        case "thread/realtime/sdp":
            return params["sdp"]?.stringValue.map { .init(kind: .answer, text: $0) }
        case "thread/realtime/transcript/delta":
            return isUser ? nil : params["delta"]?.stringValue.map { .init(kind: .assistantDelta, text: $0) }
        case "thread/realtime/transcript/done":
            return isUser ? .init(kind: .userTranscript, text: params["text"]?.stringValue) : .init(kind: .assistantDone)
        case "thread/realtime/error":
            return .init(kind: .error, text: params["message"]?.stringValue)
        case "thread/realtime/closed":
            return .init(kind: .closed)
        case "turn/completed":
            return .init(kind: .turnEnded)
        case "item/started", "item/completed":
            return params["item"].flatMap { try? JSONEncoder().encode($0) }.flatMap { LocalRealtimeEvent.toolEvent(method: event.method, item: $0) }
        default:
            return nil
        }
    }
}
