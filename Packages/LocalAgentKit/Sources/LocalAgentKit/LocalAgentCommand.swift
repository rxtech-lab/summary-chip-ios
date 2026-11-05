import Foundation

/// What the app asks the runner to launch. The runner builds the command itself, so
/// a compromised app process can't use it to run arbitrary programs outside the sandbox.
public struct LocalAgentLaunch: Codable, Sendable, Equatable {
    public var kind: LocalAgentKind
    public var mcpURL: URL
    /// Handed to the agent through its environment; it never appears in process arguments.
    public var mcpToken: String
    public var instructions: String
    /// Continues an earlier Claude Code session after an interruption.
    public var resumeSessionID: String?
    /// Nil leaves the choice to the agent's own settings.
    public var model: String?
    /// Nil uses the Codex realtime default voice.
    public var realtimeVoice: String?
    public var appToolsURL: URL? = nil
    public var appToolsToken: String? = nil

    public init(kind: LocalAgentKind, mcpURL: URL, mcpToken: String, instructions: String, resumeSessionID: String? = nil, model: String? = nil, realtimeVoice: String? = nil) {
        self.kind = kind
        self.mcpURL = mcpURL
        self.mcpToken = mcpToken
        self.instructions = instructions
        self.resumeSessionID = resumeSessionID
        self.model = model
        self.realtimeVoice = realtimeVoice
    }
}

public enum LocalAgentCommand {
    /// Named apart from `chippy` so it can't collide with a server the user configured themselves.
    public static let mcpServerName = "chippy_app"
    public static let tokenEnvironmentKey = "CHIPPY_MCP_TOKEN"

    /// Nobody is at the keyboard to approve anything in a voice session. Chippy's own tools
    /// and read-only inspection run; any other tool is denied unless the user already
    /// allowed it in their own agent settings. Writes never run unattended by default.
    static let claudeAllowedTools = ["mcp__\(mcpServerName)", "Read", "Glob", "Grep", "WebSearch", "WebFetch"]

    /// A model becomes a process argument, so it mustn't be able to read as an option.
    public static func isValidModel(_ model: String) -> Bool {
        model.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:\/\[\]-]*/) != nil
    }

    public static func arguments(for launch: LocalAgentLaunch) -> [String] {
        switch launch.kind {
        case .claudeCode: claudeArguments(launch)
        case .codex: codexArguments(launch)
        }
    }

    public static func environment(for launch: LocalAgentLaunch) -> [String: String] {
        [tokenEnvironmentKey: launch.mcpToken, "CHIPPY_APP_TOOLS_TOKEN": launch.appToolsToken ?? ""]
    }

    private static func claudeArguments(_ launch: LocalAgentLaunch) -> [String] {
        // The CLI expands the variable itself, so the config carries only its name.
        let server: [String: Any] = [
            "type": "http", "url": launch.mcpURL.absoluteString,
            "headers": ["Authorization": "Bearer ${\(tokenEnvironmentKey)}"],
        ]
        let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": [mcpServerName: server]], options: .sortedKeys)
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-mode", "default",
            "--mcp-config", String(decoding: data ?? Data(), as: UTF8.self),
            "--allowedTools", claudeAllowedTools.joined(separator: ","),
            "--append-system-prompt", launch.instructions,
        ]
        if let session = launch.resumeSessionID { arguments += ["--resume", session] }
        if let model = launch.model, isValidModel(model) { arguments += ["--model", model] }
        return arguments
    }

    private static func codexArguments(_ launch: LocalAgentLaunch) -> [String] {
        let quotedURL = String(decoding: (try? JSONEncoder().encode(launch.mcpURL.absoluteString)) ?? Data(), as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        var arguments = [
            "app-server", "--listen", "stdio://",
            "-c", "mcp_servers.\(mcpServerName).url=\(quotedURL)",
            "-c", "mcp_servers.\(mcpServerName).bearer_token_env_var=\"\(tokenEnvironmentKey)\"",
            // Approvals are off for the session, so Chippy's writes need approving up front.
            "-c", "mcp_servers.\(mcpServerName).default_tools_approval_mode=\"approve\"",
        ]
        if let url = launch.appToolsURL {
            let quoted = String(decoding: (try? JSONEncoder().encode(url.absoluteString)) ?? Data(), as: UTF8.self)
                .replacingOccurrences(of: "\\/", with: "/")
            arguments += ["-c", "mcp_servers.chippy_ui.url=\(quoted)",
                          "-c", "mcp_servers.chippy_ui.bearer_token_env_var=\"CHIPPY_APP_TOOLS_TOKEN\"",
                          "-c", "mcp_servers.chippy_ui.default_tools_approval_mode=\"approve\""]
        }
        return arguments
    }
}

/// Shared speech runtime; model repositories and revisions come from Hugging Face.
public enum LocalVoiceManifest {
    public static let runtimeVersion = "mlx-audio-0.6.3-1"
    /// Same set as RxCode's audio runtime. `misaki`'s `en` extra is spelled out to leave out PyTorch.
    public static let requirements = [
        "mlx-audio==0.6.3", "misaki[zh]==0.9.4", "num2words==0.5.14", "phonemizer-fork==3.3.2",
        "espeakng-loader==0.2.4", "spacy==3.8.18",
        "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl",
    ]

}

/// A user-chosen Hugging Face repository pinned to its downloaded revision.
public struct LocalVoiceModel: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public let revision: String
    public let title: String
    public var modelFiles: [String]? = nil
    public var sizeBytes: Int64? = nil
    public var family: String = "unknown"
    /// Voices the repository declares itself. Empty or nil means only its README can say.
    public var presetVoices: [String]? = nil
    public init(id: String, revision: String, title: String, modelFiles: [String]? = nil, sizeBytes: Int64? = nil, family: String = "unknown", presetVoices: [String]? = nil) {
        self.id = id
        self.revision = revision
        self.title = title
        self.modelFiles = modelFiles
        self.sizeBytes = sizeBytes
        self.family = family
        self.presetVoices = presetVoices
    }
    public var files: [String] { modelFiles ?? [] }
    public var repository: String { id.contains("/") ? id : "mlx-community/\(id)" }
    public var folderName: String { "\(id.replacingOccurrences(of: "/", with: "--"))-\(revision)" }
    public var treeURL: URL { URL(string: "https://huggingface.co/api/models/\(repository)/tree/\(revision)?recursive=true")! }
    public func downloadURL(for file: String) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file)")!
    }
}
