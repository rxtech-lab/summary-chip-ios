import Foundation

/// Turns streamed agent text into sentences worth speaking, leaving out what shouldn't be read aloud.
public struct SpokenTextChunker: Sendable {
    private var buffer = ""
    private var inCodeBlock = false
    /// Keeps audio from arriving as a string of tiny fragments, such as "1." in a list.
    private let minimumLength: Int

    public init(minimumLength: Int = 12) { self.minimumLength = minimumLength }

    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var sentences: [String] = []
        while let end = nextBoundary() {
            let sentence = String(buffer[..<end])
            buffer = String(buffer[end...])
            if let spoken = spokenLine(sentence) { sentences.append(spoken) }
        }
        return sentences
    }

    /// The text block ended, so whatever is left is a whole sentence.
    public mutating func flush() -> [String] {
        defer { buffer = "" }
        return spokenLine(buffer).map { [$0] } ?? []
    }

    private func nextBoundary() -> String.Index? {
        var index = buffer.startIndex
        var length = 0
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            length += 1
            if character.isNewline { return next }
            if "。！？；".contains(character), length >= 4 { return next }
            // A Western stop needs following whitespace, which keeps "3.5" and "example.com" whole.
            if ".!?".contains(character), length >= minimumLength, next < buffer.endIndex, buffer[next].isWhitespace {
                return next
            }
            index = next
        }
        return nil
    }

    private mutating func spokenLine(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { inCodeBlock.toggle(); return nil }
        if inCodeBlock { return nil }
        let spoken = Self.plainSpeech(trimmed)
        return spoken.contains(where: { $0.isLetter || $0.isNumber }) ? spoken : nil
    }

    static func plainSpeech(_ text: String) -> String {
        var text = text
        let replacements: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),          // Images
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),       // Links keep their label
            (#"https?://\S+"#, ""),                  // Nobody wants a URL read out
            (#"^\s{0,3}#{1,6}\s+"#, ""),             // Headings
            (#"^\s*[-*+]\s+"#, ""),                  // Bullets
            (#"[*_`~]{1,3}"#, ""),                   // Emphasis and inline code marks
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Decides when the user has finished speaking, from the loudness of the microphone audio.
/// Recognition results can't do this: some languages deliver nothing until the audio is finished.
public struct UtteranceDetector: Sendable {
    public enum Event: Equatable, Sendable {
        /// Speech was followed by enough quiet, so it's time to read what was said.
        case utteranceEnded
        /// A long stretch without speech, so the audio held so far can be thrown away.
        case idle
    }

    private let minimumSpeech: TimeInterval
    private let silence: TimeInterval
    private let maximumUtterance: TimeInterval
    private let idleLimit: TimeInterval
    private var noiseFloor: Double?
    private var speech: TimeInterval = 0
    private var quiet: TimeInterval = 0
    private var utterance: TimeInterval = 0
    private var idle: TimeInterval = 0
    private var isSpeaking = false

    public init(minimumSpeech: TimeInterval = 0.15, silence: TimeInterval = 0.9,
                maximumUtterance: TimeInterval = 30, idleLimit: TimeInterval = 30) {
        self.minimumSpeech = minimumSpeech
        self.silence = silence
        self.maximumUtterance = maximumUtterance
        self.idleLimit = idleLimit
    }

    /// `rms` is the loudness of the audio, from 0 to 1, over `duration` seconds.
    public mutating func process(rms: Double, duration: TimeInterval) -> Event? {
        // Exact zero means capture is muted during playback, which says nothing about the room.
        if rms > 0 {
            let floor = noiseFloor ?? rms
            // Falls quickly and rises slowly, so speech doesn't get mistaken for the room's noise.
            noiseFloor = rms < floor ? rms : floor + (rms - floor) * 0.01
        }
        let isLoud = rms > max(0.006, (noiseFloor ?? 0) * 3)
        guard isSpeaking else {
            speech = isLoud ? speech + duration : 0
            if speech >= minimumSpeech {
                isSpeaking = true
                utterance = speech
                quiet = 0
                idle = 0
                return nil
            }
            idle += duration
            if idle >= idleLimit {
                idle = 0
                return .idle
            }
            return nil
        }
        utterance += duration
        quiet = isLoud ? 0 : quiet + duration
        guard quiet >= silence || utterance >= maximumUtterance else { return nil }
        isSpeaking = false
        speech = 0
        idle = 0
        return .utteranceEnded
    }

    /// Root mean square loudness of 16-bit little-endian samples, from 0 to 1.
    public static func rms(pcm16 data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var energy = 0.0
        data.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self).prefix(count) {
                let value = Double(Int16(littleEndian: sample)) / 32768
                energy += value * value
            }
        }
        return (energy / Double(count)).squareRoot()
    }
}
