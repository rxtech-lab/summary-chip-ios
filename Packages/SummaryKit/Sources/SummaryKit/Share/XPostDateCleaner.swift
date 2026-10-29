import Foundation
import FoundationModels

/// Strips dates and times (e.g. "(2026-10-28)") from an X post's title and overview using
/// on-device Apple Intelligence. When the model is unavailable or fails, the text is kept as is.
enum XPostDateCleaner {
    @Generable
    struct Mentions {
        @Guide(description: """
            Every calendar date, weekday or clock time in the text, copied verbatim. \
            Never include version numbers, counts, prices, years used as names, or other numbers.
            """)
        var dates: [String]
    }

    static func clean(title: String, summary: String) async -> (title: String, summary: String) {
        guard SystemLanguageModel.default.isAvailable else { return (title, summary) }
        async let cleanedTitle = clean(title)
        async let cleanedSummary = clean(summary)
        return await (cleanedTitle, cleanedSummary)
    }

    /// Each field gets its own session: the small model misses dates when given both at once.
    private static func clean(_ text: String) async -> String {
        // Dates and times always contain digits, so skip the model when there are none.
        guard text.contains(where: \.isNumber) else { return text }
        let session = LanguageModelSession(instructions: """
            You find dates and times in text, such as "2026-10-28", "Oct 28, 2026", "10:30 AM" or "10月28日". \
            Version numbers like "iOS 26" or "Swift 6.2", counts and prices are not dates.
            """)
        do {
            return removing(try await session.respond(
                to: text, generating: Mentions.self, options: FoundationModels.GenerationOptions(sampling: .greedy)).content.dates, from: text)
        } catch {
            return text
        }
    }

    /// Removes the model's verbatim mentions ourselves, so the rest of the text can't be reworded.
    static func removing(_ dates: [String], from text: String) -> String {
        var result = text
        for date in dates.map({ $0.trimmingCharacters(in: .whitespaces) }) where isDate(date) {
            // Also drop the preposition that introduced it ("on 2026-10-28", "在 10月28日").
            let pattern = #"(?:\b(?:on|at|in)\s+|[在于]\s*)?"# + NSRegularExpression.escapedPattern(for: date)
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        guard result != text else { return text }
        // Drop brackets and separators the removal left empty, then tidy spacing.
        let tidy = [(#"[(\[（【]\s*[)\]）】]"#, ""), (#"[ \t]{2,}"#, " "), (#"[ \t]+([,.!?;:，。！？；：])"#, "$1")]
        for (pattern, template) in tidy {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|·:,")))
        return result.isEmpty ? text : result
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Double-checks the model: a mention must be a detected date, plus at most a short
    /// preposition, so names like "Rust 2024 edition" are never removed.
    static func isDate(_ mention: String) -> Bool {
        let range = NSRange(mention.startIndex..., in: mention)
        guard let detector, mention.contains(where: \.isNumber),
              let match = detector.firstMatch(in: mention, range: range),
              let matched = Range(match.range, in: mention) else { return false }
        var rest = mention
        rest.removeSubrange(matched)
        let words = rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.count <= 1 && words.allSatisfy { $0.count <= 4 && !$0.contains(where: \.isNumber) }
    }
}
