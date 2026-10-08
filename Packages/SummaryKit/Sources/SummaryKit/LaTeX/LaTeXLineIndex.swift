import Foundation

/// Where each line of a text starts, for turning UTF-16 offsets into 1-based line numbers (the
/// gutter, compile errors, hover cards) and back.
public struct LaTeXLineIndex: Sendable, Equatable {
    /// UTF-16 offset of the first character of each line; the first is always 0.
    public let starts: [Int]
    public let length: Int

    public init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        self.starts = starts
        self.length = offset
    }

    public var lineCount: Int { starts.count }

    /// The 1-based line holding `offset`.
    public func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    /// The range of 1-based `line` without its line break, or nil past the end.
    public func range(ofLine line: Int) -> NSRange? {
        guard line >= 1, line <= starts.count else { return nil }
        let start = starts[line - 1]
        let end = line < starts.count ? starts[line] - 1 : length
        return NSRange(location: start, length: end - start)
    }
}
