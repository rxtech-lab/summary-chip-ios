import SummaryKit
import SwiftUI

/// A request to put the cursor on a line of the open file (a LaTeX error was picked).
struct PaperLineJump: Equatable {
    let line: Int
    let id = UUID()
}

/// A LaTeX editor in the style of a code editor:
/// * syntax highlighting for `.tex` and `.bib` files, and the bracket at the caret marked with its
///   partner; typing `{` adds its `}`;
/// * line numbers, with the lines that have compile or reference errors tinted, underlined with a
///   red wave, numbered in red over a wave and showing the message in a pill;
/// * completion of commands, environments, labels, citation keys and file paths, each with a
///   description (`symbols` scans the whole paper, only when needed);
/// * hover cards describing the word under the pointer and the errors on its line (Mac, iPad with a
///   pointer; on touch the bar over the keyboard describes the word at the caret).
///
/// Smart quotes, dashes, autocorrection and spell checking are off (they would turn `--` and `"`
/// into characters TeX doesn't expect). `fileID` changes when another file is opened, which resets
/// the cursor and undo history.
struct PaperSourceEditor: View {
    @Binding var text: String
    let fileID: String
    let language: LaTeXLanguage
    let isEditable: Bool
    var jump: PaperLineJump?
    var issues: [PaperEditorIssue] = []
    var symbols: () -> LaTeXSymbols = { LaTeXSymbols() }
    var onImageDrop: (([NSItemProvider]) -> Bool)?

    var body: some View {
        PlatformSourceEditor(
            text: $text,
            fileID: fileID,
            language: language,
            isEditable: isEditable,
            jump: jump,
            issues: issues,
            symbols: symbols,
            onImageDrop: onImageDrop
        )
        .accessibilityIdentifier("paper-editor")
    }
}

/// The character range of 1-based `line` in `text`, for selecting it.
func paperRange(ofLine line: Int, in text: NSString) -> NSRange {
    var location = 0
    var current = 1
    while current < line, location < text.length {
        let next = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
        guard next.location != NSNotFound else { break }
        location = next.location + 1
        current += 1
    }
    return text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
}

/// Remembers what was last applied, so SwiftUI updates only touch the view when something changed.
final class PaperSourceEditorState {
    var fileID: String?
    var jumpID: UUID?
    var onChange: ((String) -> Void)?
    var symbols: () -> LaTeXSymbols = { LaTeXSymbols() }
}

extension [PaperEditorIssue] {
    /// The messages by line, for drawing and hover cards.
    var byLine: [Int: [String]] { Dictionary(grouping: self, by: \.line).mapValues { $0.map(\.message) } }
}
