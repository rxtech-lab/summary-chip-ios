import Foundation

/// Works out which named voices a model offers, from its own files or from its README.
public enum VoiceCatalog {
    /// Voices the repository itself declares: `voices/*.safetensors` files and `spk_id` in its config.
    public static func presetVoices(files: [String], config: [String: Any]) -> [String] {
        let bundled = files.compactMap { path -> String? in
            guard path.hasPrefix("voices/"), path.hasSuffix(".safetensors") else { return nil }
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        let talker = config["talker_config"] as? [String: Any]
        let speakers = (config["spk_id"] as? [String: Any]) ?? (talker?["spk_id"] as? [String: Any]) ?? [:]
        return Array(Set(bundled).union(speakers.keys)).sorted()
    }

    /// The README lines about voices with a little context, small enough for an on-device model.
    /// Empty when the README never mentions voices, so there's nothing to ask about.
    public static func readmeExcerpt(_ readme: String, limit: Int = 5000) -> String {
        let keywords = ["voice", "speaker", "spk_", "声音", "音色", "说话人", "語者", "ボイス", "話者"]
        let lines = readme.components(separatedBy: .newlines)
        var kept = IndexSet()
        for (index, line) in lines.enumerated() {
            let lowered = line.lowercased()
            guard keywords.contains(where: lowered.contains) else { continue }
            kept.insert(integersIn: max(0, index - 2)...min(lines.count - 1, index + 4))
        }
        let excerpt = kept.map { lines[$0] }.joined(separator: "\n")
        return String(excerpt.prefix(limit))
    }

    /// Keeps only well-formed names that really appear in the README, so a guess can't reach the picker.
    public static func grounded(_ names: [String], in readme: String) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "`\"'*")))
            guard (1...40).contains(trimmed.count),
                  trimmed.allSatisfy({ $0.isLetter || $0.isNumber || " _-.".contains($0) }),
                  readme.range(of: trimmed, options: .caseInsensitive) != nil,
                  seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}
