import Foundation

/// What changed between two states of a paper's source, file by file and line by line: how the
/// app shows an agent's edits for a review (`docs/papers.md` → Reviews). Computed from the two
/// versions' files; images compare by their asset key.
public struct PaperDiff: Sendable, Hashable {
    public enum Change: Sendable, Hashable { case added, removed, modified }

    public struct Line: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case same, added, removed }

        public var kind: Kind
        public var text: String
        /// The line's number in the old file (nil when added) and in the new one (nil when removed).
        public var oldNumber: Int?
        public var newNumber: Int?

        public var id: String { "\(oldNumber ?? 0):\(newNumber ?? 0):\(kind)" }
    }

    /// Lines around a change, with context, the way a patch shows them.
    public struct Hunk: Sendable, Hashable, Identifiable {
        public var lines: [Line]
        public var id: String { lines.first?.id ?? "" }
    }

    public struct File: Sendable, Hashable, Identifiable {
        public var path: String
        public var change: Change
        public var hunks: [Hunk]
        public var isImage: Bool
        public var added: Int
        public var removed: Int

        public var id: String { path }
    }

    public var files: [File]

    public var isEmpty: Bool { files.isEmpty }
    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }

    /// The files that differ between `old` and `new`, in the new source's reading order (removed files last).
    public init(old: PaperSource, new: PaperSource, context: Int = 2) {
        var files: [File] = []
        for file in new.orderedFiles {
            guard let before = old.file(file.path) else {
                let lines = file.isImage ? [] : Self.lines(file.content).enumerated().map { Line(kind: .added, text: $1, oldNumber: nil, newNumber: $0 + 1) }
                files.append(File(path: file.path, change: .added, hunks: lines.isEmpty ? [] : [Hunk(lines: lines)], isImage: file.isImage, added: lines.count, removed: 0))
                continue
            }
            if file.isImage || before.isImage {
                if file.asset?.key != before.asset?.key { files.append(File(path: file.path, change: .modified, hunks: [], isImage: true, added: 0, removed: 0)) }
                continue
            }
            guard file.content != before.content else { continue }
            let lines = Self.diff(Self.lines(before.content), Self.lines(file.content))
            let hunks = Self.hunks(lines, context: context)
            files.append(File(
                path: file.path, change: .modified, hunks: hunks, isImage: false,
                added: lines.filter { $0.kind == .added }.count, removed: lines.filter { $0.kind == .removed }.count
            ))
        }
        for file in old.orderedFiles where new.file(file.path) == nil {
            let lines = file.isImage ? [] : Self.lines(file.content).enumerated().map { Line(kind: .removed, text: $1, oldNumber: $0 + 1, newNumber: nil) }
            files.append(File(path: file.path, change: .removed, hunks: lines.isEmpty ? [] : [Hunk(lines: lines)], isImage: file.isImage, added: 0, removed: lines.count))
        }
        self.files = files
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.hasSuffix("\r") ? $0.dropLast() : $0) }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The lines of both files in order, each marked same, added or removed: a longest common
    /// subsequence, so a moved paragraph shows as removed and added rather than as noise.
    static func diff(_ old: [String], _ new: [String]) -> [Line] {
        // Common head and tail first, so the quadratic part only sees the changed middle.
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let oldMiddle = Array(old[head..<(old.count - tail)])
        let newMiddle = Array(new[head..<(new.count - tail)])
        var result: [Line] = []
        for index in 0..<head { result.append(Line(kind: .same, text: old[index], oldNumber: index + 1, newNumber: index + 1)) }
        result += middle(oldMiddle, newMiddle, oldStart: head + 1, newStart: head + 1)
        for index in 0..<tail {
            let oldIndex = old.count - tail + index
            let newIndex = new.count - tail + index
            result.append(Line(kind: .same, text: old[oldIndex], oldNumber: oldIndex + 1, newNumber: newIndex + 1))
        }
        return result
    }

    private static func middle(_ old: [String], _ new: [String], oldStart: Int, newStart: Int) -> [Line] {
        // Very long changes aren't matched line by line: the whole middle is replaced.
        guard old.count * new.count <= 4_000_000, !old.isEmpty, !new.isEmpty else {
            return old.enumerated().map { Line(kind: .removed, text: $1, oldNumber: oldStart + $0, newNumber: nil) }
                + new.enumerated().map { Line(kind: .added, text: $1, oldNumber: nil, newNumber: newStart + $0) }
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                result.append(Line(kind: .same, text: old[i], oldNumber: oldStart + i, newNumber: newStart + j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(Line(kind: .removed, text: old[i], oldNumber: oldStart + i, newNumber: nil))
                i += 1
            } else {
                result.append(Line(kind: .added, text: new[j], oldNumber: nil, newNumber: newStart + j))
                j += 1
            }
        }
        while i < old.count { result.append(Line(kind: .removed, text: old[i], oldNumber: oldStart + i, newNumber: nil)); i += 1 }
        while j < new.count { result.append(Line(kind: .added, text: new[j], oldNumber: nil, newNumber: newStart + j)); j += 1 }
        return result
    }

    /// Groups the changed lines with `context` unchanged lines around them.
    static func hunks(_ lines: [Line], context: Int) -> [Hunk] {
        var hunks: [Hunk] = []
        var current: [Line] = []
        var sinceChange = Int.max
        var pending: [Line] = []
        for line in lines {
            if line.kind == .same {
                if sinceChange < context {
                    current.append(line)
                    sinceChange += 1
                } else {
                    pending.append(line)
                    if pending.count > context { pending.removeFirst() }
                    if !current.isEmpty, sinceChange >= context { hunks.append(Hunk(lines: current)); current = [] }
                }
            } else {
                if current.isEmpty { current = pending } else { current += pending }
                pending = []
                current.append(line)
                sinceChange = 0
            }
        }
        if !current.isEmpty { hunks.append(Hunk(lines: current)) }
        return hunks
    }
}
