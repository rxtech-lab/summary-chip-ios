import LocalAgentKit

/// Where the user's last live voice pick is remembered.
enum LiveVoiceSettings {
    static let engineKey = "liveVoiceEngine"
    static let languageKey = "liveVoiceLanguage"

    /// Each agent has its own models, so each remembers its own pick. Empty means the agent's default.
    static func modelKey(for agent: LocalAgentKind) -> String { "liveVoiceModel.\(agent.rawValue)" }
}
