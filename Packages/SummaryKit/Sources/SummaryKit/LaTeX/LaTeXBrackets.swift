import Foundation

/// A bracket next to the caret and the one it pairs with (nil when it has none).
public struct LaTeXBracketMatch: Sendable, Equatable {
    public let bracket: NSRange
    public let partner: NSRange?
}

/// Bracket matching and pairing for the editor. `\{`, `\}` and brackets in `%` comments don't count.
public enum LaTeXBrackets {
    /// How far a match is looked for, so a stray brace in a long file stays cheap.
    static let scanLimit = 50_000

    private static let pairs: [UInt16: (partner: UInt16, opens: Bool)] = [
        unit("{"): (unit("}"), true), unit("}"): (unit("{"), false),
        unit("["): (unit("]"), true), unit("]"): (unit("["), false),
        unit("("): (unit(")"), true), unit(")"): (unit("("), false),
    ]

    /// The bracket just before the caret (else just after) and its partner.
    public static func match(in text: String, at cursor: Int) -> LaTeXBracketMatch? {
        let string = text as NSString
        for index in [cursor - 1, cursor] where index >= 0 && index < string.length {
            let char = string.character(at: index)
            guard let pair = pairs[char], !LaTeXCompletion.isEscaped(string, index), !isInComment(string, index) else { continue }
            let partner = pair.opens
                ? scanForward(string, from: index + 1, open: char, close: pair.partner)
                : scanBackward(string, from: index - 1, open: pair.partner, close: char)
            return LaTeXBracketMatch(bracket: NSRange(location: index, length: 1), partner: partner.map { NSRange(location: $0, length: 1) })
        }
        return nil
    }

    /// Typing pairs braces: `{` adds its `}` (unless it's `\{` or a word follows), typing `}` steps
    /// over the `}` already there, and deleting a `{` right before its `}` deletes both.
    /// Nil leaves the typing to the text view.
    public static func autoPair(in text: String, replacing range: NSRange, with replacement: String) -> LaTeXCompletionEdit? {
        let string = text as NSString
        let next = NSMaxRange(range) < string.length ? string.character(at: NSMaxRange(range)) : nil
        switch replacement {
        case "{" where range.length == 0:
            let previous = range.location > 0 ? string.character(at: range.location - 1) : nil
            if previous == LaTeXCompletion.backslash && !LaTeXCompletion.isEscaped(string, range.location - 1) { return nil }
            if let next, let scalar = UnicodeScalar(next), CharacterSet.alphanumerics.contains(scalar) || next == LaTeXCompletion.backslash { return nil }
            return LaTeXCompletionEdit(range: range, text: "{}", selection: NSRange(location: range.location + 1, length: 0))
        case "}" where range.length == 0 && next == unit("}"):
            return LaTeXCompletionEdit(range: NSRange(location: range.location, length: 0), text: "", selection: NSRange(location: range.location + 1, length: 0))
        case "" where range.length == 1 && string.character(at: range.location) == unit("{") && next == unit("}")
            && !LaTeXCompletion.isEscaped(string, range.location):
            return LaTeXCompletionEdit(range: NSRange(location: range.location, length: 2), text: "", selection: NSRange(location: range.location, length: 0))
        default:
            return nil
        }
    }

    private static func scanForward(_ string: NSString, from start: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var index = start
        let end = min(string.length, start + scanLimit)
        while index < end {
            let char = string.character(at: index)
            if char == unit("%"), !LaTeXCompletion.isEscaped(string, index) {
                let line = string.lineRange(for: NSRange(location: index, length: 0))
                index = NSMaxRange(line)
                continue
            }
            if char == open || char == close, !LaTeXCompletion.isEscaped(string, index) {
                if char == close {
                    if depth == 0 { return index }
                    depth -= 1
                } else {
                    depth += 1
                }
            }
            index += 1
        }
        return nil
    }

    private static func scanBackward(_ string: NSString, from start: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var index = start
        let end = max(0, start - scanLimit)
        // Brackets after a line's comment sign don't count; find it once per line.
        var lineStart = Int.max
        var commentStart = Int.max
        while index >= end {
            if index < lineStart {
                let line = string.lineRange(for: NSRange(location: index, length: 0))
                lineStart = line.location
                commentStart = self.commentStart(string, in: line) ?? Int.max
            }
            let char = string.character(at: index)
            if index < commentStart, char == open || char == close, !LaTeXCompletion.isEscaped(string, index) {
                if char == open {
                    if depth == 0 { return index }
                    depth -= 1
                } else {
                    depth += 1
                }
            }
            index -= 1
        }
        return nil
    }

    private static func isInComment(_ string: NSString, _ index: Int) -> Bool {
        let line = string.lineRange(for: NSRange(location: index, length: 0))
        return commentStart(string, in: line).map { $0 < index } ?? false
    }

    private static func commentStart(_ string: NSString, in line: NSRange) -> Int? {
        var index = line.location
        while index < NSMaxRange(line) {
            if string.character(at: index) == unit("%"), !LaTeXCompletion.isEscaped(string, index) { return index }
            index += 1
        }
        return nil
    }

    private static func unit(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }
}
