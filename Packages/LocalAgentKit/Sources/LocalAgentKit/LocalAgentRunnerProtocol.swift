import Foundation

#if os(macOS)
public let localAgentRunnerServiceName = "com.rxlab.summary-chip.LocalAgentRunner"

/// What the sandboxed app can ask of the runner. Sandboxed apps pass their sandbox on to anything they
/// launch, which agents can't work under, so they run from this embedded service instead. Only
/// named operations exist here: there's deliberately no way to run an arbitrary command.
@objc public protocol LocalAgentRunnerProtocol {
    /// Encoded `LocalAgentRunnerStatus`.
    func status(reply: @escaping @Sendable (Data) -> Void)
    /// `request` is an encoded `LocalAgentLaunch`. Replies with an error message, or nil once running.
    func startAgent(id: String, request: Data, reply: @escaping @Sendable (String?) -> Void)
    /// `modelID` is nil for the selected model, or a downloaded one to play a sample from.
    func startSpeechWorker(id: String, modelID: String?, seed: Int, reply: @escaping @Sendable (String?) -> Void)
    /// `kind` is a `LocalAgentKind`. Replies with encoded `[AgentModelOption]`, empty if it isn't installed.
    func agentModels(kind: String, reply: @escaping @Sendable (Data) -> Void)
    /// `offer` is the app's complete WebRTC offer; the answer comes back as a `LocalRealtimeEvent`.
    func startRealtime(id: String, request: Data, offer: String, reply: @escaping @Sendable (String?) -> Void)
    func write(id: String, data: Data)
    func terminate(id: String)
    /// Installs the runtime and downloads the model, reporting through `voiceSetupProgress`.
    func prepareVoice(reply: @escaping @Sendable (String?) -> Void)
    func downloadVoiceModel(repository: String, revision: String, reply: @escaping @Sendable (String?) -> Void)
    func manageVoiceModel(id: String, action: String, reply: @escaping @Sendable (String?) -> Void)
    func cancelVoiceSetup()
}

@objc public protocol LocalAgentRunnerClientProtocol {
    func processLine(id: String, line: Data)
    func processExited(id: String, status: Int32, message: String?)
    /// Encoded `LocalVoiceSetupProgress`.
    func voiceSetupProgress(_ data: Data)
}
#endif

public struct LocalAgentInstall: Codable, Sendable, Equatable {
    public var kind: LocalAgentKind
    public var path: String?
    public var version: String?

    public init(kind: LocalAgentKind, path: String?, version: String?) {
        self.kind = kind
        self.path = path
        self.version = version
    }
}

public struct LocalAgentRunnerStatus: Codable, Sendable, Equatable {
    public var voiceModels: [LocalVoiceModel] = []
    public var selectedVoiceModel: String = ""
    public var downloadedVoiceModels: [String] = []
    public var storedVoiceModels: [String] = []
    public var agents: [LocalAgentInstall]
    public var hasUV: Bool
    public var voiceReady: Bool
    public var isAppleSilicon: Bool

    public init(agents: [LocalAgentInstall], hasUV: Bool, voiceReady: Bool, isAppleSilicon: Bool) {
        self.agents = agents
        self.hasUV = hasUV
        self.voiceReady = voiceReady
        self.isAppleSilicon = isAppleSilicon
    }

    public func install(for kind: LocalAgentKind) -> LocalAgentInstall? { agents.first { $0.kind == kind } }
}

public struct LocalVoiceSetupProgress: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case runtime, model }
    public var phase: Phase
    public var fraction: Double?

    public init(phase: Phase, fraction: Double?) {
        self.phase = phase
        self.fraction = fraction
    }
}

/// Picks the voice of a model with no preset voices.
public enum LocalVoiceSeed {
    /// What every model used before seeds could be chosen, so existing voices stay the same.
    public static let standard = 7
    public static let range = 0...999_999
}

/// One message from the speech worker.
public enum SpeechWorkerEvent: Equatable, Sendable {
    case ready
    case audio(id: String, pcm: Data)
    case done(id: String)
    case error(id: String?, message: String)
    case fatal(String)

    public init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let id = object["id"] as? String
        switch type {
        case "ready": self = .ready
        case "audio":
            guard let id, let pcm = (object["pcm"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            self = .audio(id: id, pcm: pcm)
        case "done":
            guard let id else { return nil }
            self = .done(id: id)
        case "error": self = .error(id: id, message: object["message"] as? String ?? "Speech failed.")
        case "fatal": self = .fatal(object["message"] as? String ?? "The voice model couldn't load.")
        default: return nil
        }
    }

    /// `voice` is the user's choice; without one the worker uses the model's default for the language.
    /// A model with no preset voices gets its voice from `seed`.
    public static func speakLine(id: String, text: String, language: LocalVoiceLanguage, voice: String? = nil, seed: Int? = nil) -> Data {
        var object: [String: Any] = ["type": "speak", "id": id, "text": text, "defaultVoice": language.kokoroVoice, "lang": language.kokoroLanguage]
        if let voice { object["voice"] = voice }
        if let seed { object["seed"] = seed }
        return ((try? JSONSerialization.data(withJSONObject: object)) ?? Data()) + Data("\n".utf8)
    }

    public static let cancelLine = Data("{\"type\":\"cancel\"}\n".utf8)
}

/// Signaling, transcripts and tool activity from Codex. Audio itself flows over the app's WebRTC connection.
public struct LocalRealtimeEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case answer, assistantDelta, assistantDone, userTranscript, error, closed, tool
        /// The Codex thread finished, was interrupted or failed. No more tools run until the next one.
        case turnEnded
    }
    public let kind: Kind
    public var text: String?
    /// Set when `kind` is `tool`.
    public var tool: LocalAgentEvent?
    public init(kind: Kind, text: String? = nil, tool: LocalAgentEvent? = nil) {
        self.kind = kind; self.text = text; self.tool = tool
    }

    /// The realtime model hands requests to a Codex thread, whose MCP calls arrive as thread items.
    /// `item` is the JSON of an `item/started` or `item/completed` notification's item.
    public static func toolEvent(method: String, item: Data) -> LocalRealtimeEvent? {
        guard let item = (try? JSONSerialization.jsonObject(with: item)) as? [String: Any],
              item["type"] as? String == "mcpToolCall", let id = item["id"] as? String,
              let server = item["server"] as? String, let name = item["tool"] as? String else { return nil }
        switch method {
        case "item/started":
            let arguments = item["arguments"].flatMap { JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil }
            return .init(kind: .tool, tool: .toolStarted(id: id, name: "mcp__\(server)__\(name)", input: arguments ?? Data("{}".utf8)))
        case "item/completed":
            let result = item["result"] as? [String: Any]
            let error = (item["error"] as? [String: Any])?["message"] as? String
            let output = result.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }
            let failed = error != nil || item["status"] as? String == "failed" || result?["isError"] as? Bool == true
            return .init(kind: .tool, tool: .toolFinished(id: id, output: error ?? output ?? "", isError: failed))
        default:
            return nil
        }
    }
}
