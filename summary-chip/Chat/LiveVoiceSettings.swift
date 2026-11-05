import LocalAgentKit

/// Where the user's last live voice pick is remembered.
enum LiveVoiceSettings {
    static let engineKey = "liveVoiceEngine"
    static let realtimeVoiceKey = "liveVoiceCodexRealtimeVoice"
    // Voices supported by Codex realtime v3 (the general protocol enum also includes older voices).
    static let realtimeVoices = ["juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol", "cove", "aube", "bubbie", "haetsal", "hanul", "himari", "leher", "miko", "neer", "porto", "rindo", "rio", "rivage", "selva", "sonna", "tinta", "viola"]
    static let languageKey = "liveVoiceLanguage"

    /// Each agent has its own models, so each remembers its own pick. Empty means the agent's default.
    static func modelKey(for agent: LocalAgentKind) -> String { "liveVoiceModel.\(agent.rawValue)" }
}
