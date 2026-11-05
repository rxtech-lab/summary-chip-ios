import Foundation

/// Who answers in live voice. The raw value is what's saved as the user's last pick.
public enum LiveVoiceEngine: String, CaseIterable, Identifiable, Sendable {
    case chippy, claudeCode, codex

    public var id: String { rawValue }
    public var localAgent: LocalAgentKind? {
        switch self {
        case .chippy: nil
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }

    /// A saved pick from a newer version, or none yet, means Chippy's cloud voice.
    public init(saved: String?) { self = saved.flatMap(Self.init(rawValue:)) ?? .chippy }
}

public enum LocalAgentKind: String, Codable, CaseIterable, Sendable {
    case claudeCode, codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    public var executableName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }
}

/// A language both Apple's speech recognition and a Kokoro voice can handle.
public struct LocalVoiceLanguage: Identifiable, Hashable, Sendable {
    public let localeIdentifier: String
    public let kokoroLanguage: String
    public let kokoroVoice: String
    public var id: String { localeIdentifier }

    /// Read aloud to try a voice, in the language it will be speaking.
    public var sampleText: String {
        switch String(localeIdentifier.prefix(2)) {
        case "zh": "你好，这是我说话的声音。我可以为你朗读摘要，也可以回答关于资料库的问题。"
        case "es": "Hola, así sonará mi voz. Puedo leerte tus resúmenes y responder preguntas sobre tu biblioteca."
        case "fr": "Bonjour, voici le son de ma voix. Je peux lire vos résumés et répondre à vos questions sur votre bibliothèque."
        case "it": "Ciao, questa è la mia voce. Posso leggere i tuoi riassunti e rispondere alle domande sulla tua libreria."
        case "pt": "Olá, esta é a minha voz. Posso ler seus resumos e responder perguntas sobre a sua biblioteca."
        default: "Hello, this is how I'll sound. I can read your summaries aloud and answer questions about your library."
        }
    }

    /// Each entry was exercised through the speech worker. Cantonese and Japanese are absent
    /// because Kokoro has no Cantonese voice and the runtime leaves out Japanese text support.
    public static let all: [LocalVoiceLanguage] = [
        .init(localeIdentifier: "en-US", kokoroLanguage: "a", kokoroVoice: "af_heart"),
        .init(localeIdentifier: "en-GB", kokoroLanguage: "b", kokoroVoice: "bf_emma"),
        .init(localeIdentifier: "zh-CN", kokoroLanguage: "z", kokoroVoice: "zf_xiaobei"),
        .init(localeIdentifier: "es-ES", kokoroLanguage: "e", kokoroVoice: "ef_dora"),
        .init(localeIdentifier: "fr-FR", kokoroLanguage: "f", kokoroVoice: "ff_siwis"),
        .init(localeIdentifier: "it-IT", kokoroLanguage: "i", kokoroVoice: "if_sara"),
        .init(localeIdentifier: "pt-BR", kokoroLanguage: "p", kokoroVoice: "pf_dora"),
    ]

    /// The saved pick, else the closest match for the device language, else American English.
    public static func resolve(saved: String?, preferred: [String] = Locale.preferredLanguages) -> LocalVoiceLanguage {
        if let saved, let match = all.first(where: { $0.localeIdentifier == saved }) { return match }
        for identifier in preferred {
            if let exact = all.first(where: { $0.localeIdentifier.caseInsensitiveCompare(identifier) == .orderedSame }) { return exact }
            let locale = Locale(identifier: identifier)
            // Traditional Chinese would be misheard and read aloud as Mandarin, so it doesn't match.
            if locale.language.languageCode?.identifier == "zh", locale.language.script?.identifier == "Hant" { continue }
            if let code = locale.language.languageCode?.identifier,
               let match = all.first(where: { Locale(identifier: $0.localeIdentifier).language.languageCode?.identifier == code }) {
                return match
            }
        }
        return all[0]
    }
}
