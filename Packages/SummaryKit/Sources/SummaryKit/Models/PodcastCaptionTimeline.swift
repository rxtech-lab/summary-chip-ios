import Foundation

/// Short, readable phrases from a spoken turn. The speech model gives no word timestamps, so phrase
/// timing is estimated from how long each phrase takes to say, and snapped to the pauses measured in
/// the recording where the text has punctuation. The audio and original transcript remain unchanged.
public struct PodcastCaptionTimeline: Sendable {
    /// Where a turn's voice is audible and where it pauses, in episode seconds.
    public struct Timing: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var pauses: [Double]
        public init(start: Double, end: Double, pauses: [Double] = []) {
            self.start = start
            self.end = end
            self.pauses = pauses
        }
    }

    public let phrases: [String]
    private let endings: [Int]
    private let count: Int
    /// Estimated speaking weight up to the end of each phrase, and whether the phrase ends in punctuation.
    private let weights: [Double]
    private let punctuated: [Bool]

    public init(_ text: String) {
        let characters = Array(text)
        let compactScript = text.unicodeScalars.contains {
            $0.properties.isIdeographic || (0x3040...0x30ff).contains($0.value) || (0xac00...0xd7af).contains($0.value)
        }
        // Short enough that one phrase fits a single caption line on a phone.
        let limit = compactScript ? 18 : 36
        let punctuation = CharacterSet(charactersIn: ".!?。！？;；,，:：\n")
        var phrases: [String] = []
        var endings: [Int] = []
        var weights: [Double] = []
        var punctuated: [Bool] = []
        var total = 0.0
        var start = 0
        while start < characters.count {
            let ceiling = min(start + limit, characters.count)
            var end = ceiling
            if let boundary = (start..<ceiling).first(where: { index in
                characters[index].unicodeScalars.contains { punctuation.contains($0) }
            }) {
                end = boundary + 1
            } else if ceiling < characters.count,
                      let space = (start..<ceiling).last(where: { characters[$0].isWhitespace }), space > start {
                end = space + 1
            }
            let phrase = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            total += characters[start..<end].reduce(0) { $0 + Self.weight(of: $1) }
            if !phrase.isEmpty {
                phrases.append(phrase)
                endings.append(end)
                weights.append(total)
                punctuated.append(characters[end - 1].unicodeScalars.contains { punctuation.contains($0) })
            }
            start = end
        }
        self.phrases = phrases
        self.endings = endings
        self.count = characters.count
        self.weights = weights
        self.punctuated = punctuated
    }

    /// Rough speaking time of a character: digits are read as whole words ("2026" → "twenty twenty-six"),
    /// and punctuation takes no time of its own because its pause is measured from the audio.
    private static func weight(of character: Character) -> Double {
        if character.isNumber { return 2.5 }
        if character.isWhitespace { return 0.5 }
        if character.isLetter || character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return 1 }
        return 0
    }

    /// The time each phrase finishes. Sentence and clause ends snap to the nearest measured pause that
    /// is closer to them than to the next break; phrases between those anchors share the time by weight.
    public func phraseEnds(_ timing: Timing) -> [Double] {
        guard let total = weights.last, total > 0, timing.end > timing.start else { return weights.map { _ in timing.end } }
        var anchors: [(weight: Double, time: Double)] = [(0, timing.start)]
        var pauses = timing.pauses.filter { $0 > timing.start && $0 < timing.end }.sorted()
        func estimate(_ index: Int) -> Double {
            let last = anchors[anchors.count - 1]
            return last.time + (weights[index] - last.weight) / max(total - last.weight, .ulpOfOne) * (timing.end - last.time)
        }
        let breaks = phrases.indices.dropLast().filter { punctuated[$0] }
        let tolerance = max(0.6, (timing.end - timing.start) * 0.15)
        for (position, index) in breaks.enumerated() {
            let expected = estimate(index)
            guard let pause = pauses.min(by: { abs($0 - expected) < abs($1 - expected) }) else { break }
            if abs(pause - expected) > tolerance { continue }
            if position + 1 < breaks.count, abs(pause - estimate(breaks[position + 1])) < abs(pause - expected) { continue }
            anchors.append((weights[index], pause))
            pauses.removeAll { $0 <= pause }
        }
        anchors.append((total, timing.end))
        var segment = 0
        return weights.map { weight in
            while segment < anchors.count - 2 && anchors[segment + 1].weight < weight { segment += 1 }
            let (a, b) = (anchors[segment], anchors[segment + 1])
            return b.weight > a.weight ? a.time + (weight - a.weight) / (b.weight - a.weight) * (b.time - a.time) : b.time
        }
    }

    /// The caption lines on screen at episode `time`, given the turn's measured timing.
    public func lines(at time: Double, timing: Timing) -> [String] {
        guard !phrases.isEmpty else { return [] }
        let ends = phraseEnds(timing)
        return page(containing: time.isFinite ? ends.firstIndex { $0 > time } ?? phrases.count - 1 : 0)
    }

    /// The two caption lines on screen at `progress`. Lines advance as a page of two phrases so the
    /// text doesn't shift on every phrase, and punctuation is shown as spaces.
    public func lines(at progress: Double) -> [String] {
        guard !phrases.isEmpty else { return [] }
        let fraction = progress.isFinite ? max(0, min(1, progress)) : 0
        let offset = Int(Double(count) * fraction)
        return page(containing: endings.firstIndex { $0 > offset } ?? phrases.count - 1)
    }

    private func page(containing index: Int) -> [String] {
        let page = index - index % 2
        return phrases[page..<min(page + 2, phrases.count)].map(Self.withoutPunctuation).filter { !$0.isEmpty }
    }

    public func caption(at progress: Double) -> String {
        lines(at: progress).joined(separator: "\n")
    }

    /// Replaces punctuation with spaces, keeping apostrophes and hyphens inside words ("Here's", "e-mail").
    static func withoutPunctuation(_ phrase: String) -> String {
        let characters = Array(phrase)
        let mapped = characters.indices.map { index -> Character in
            let character = characters[index]
            guard character.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) else { return character }
            if "'’-".contains(character), index > 0, index < characters.count - 1,
               characters[index - 1].isLetter, characters[index + 1].isLetter {
                return character
            }
            return " "
        }
        return String(mapped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
