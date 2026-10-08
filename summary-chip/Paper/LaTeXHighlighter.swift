import SummaryKit
#if os(iOS)
import UIKit

typealias EditorColor = UIColor
typealias EditorFont = UIFont
typealias TextStorageEditActions = NSTextStorage.EditActions

extension EditorColor {
    static var editorText: EditorColor { .label }
    static var editorSecondaryText: EditorColor { .secondaryLabel }
    static var editorGutter: EditorColor { .secondarySystemBackground }
}
#else
import AppKit

typealias EditorColor = NSColor
typealias EditorFont = NSFont
typealias TextStorageEditActions = NSTextStorageEditActions

extension EditorColor {
    static var editorText: EditorColor { .textColor }
    static var editorSecondaryText: EditorColor { .secondaryLabelColor }
    static var editorGutter: EditorColor { .controlBackgroundColor }
}
#endif

/// Colours the paper editor's text as it changes, as the delegate of the text view's storage, and
/// marks the bracket at the caret with its partner. Small files are recoloured whole on every edit
/// (so math spanning lines stays right); large ones only in the edited paragraphs, to keep typing fast.
final class LaTeXHighlighter: NSObject, NSTextStorageDelegate {
    static let fullPassLimit = 60_000

    var language: LaTeXLanguage = .plain
    private let font: EditorFont
    private let boldFont: EditorFont
    /// Bracket marks, kept so a recolouring pass puts them back.
    private var brackets: [(range: NSRange, color: EditorColor)] = []

    init(fontSize: CGFloat) {
        font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
    }

    var baseAttributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: EditorColor.editorText] }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: TextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let all = NSRange(location: 0, length: textStorage.length)
        let scope = textStorage.length <= Self.fullPassLimit ? all : (textStorage.string as NSString).paragraphRange(for: editedRange)
        highlight(textStorage, in: scope)
    }

    /// Marks the bracket next to `cursor` and its partner (yellow), or a bracket without one (red).
    func markBrackets(at cursor: Int?, in storage: NSTextStorage) {
        let match = cursor.flatMap { language == .plain ? nil : LaTeXBrackets.match(in: storage.string, at: $0) }
        let next: [(range: NSRange, color: EditorColor)] = match.map { match in
            guard let partner = match.partner else { return [(match.bracket, EditorColor.systemRed.withAlphaComponent(0.3))] }
            return [match.bracket, partner].map { ($0, EditorColor.systemYellow.withAlphaComponent(0.45)) }
        } ?? []
        guard next.map(\.range) != brackets.map(\.range) else { return }
        storage.beginEditing()
        for old in brackets where NSMaxRange(old.range) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: old.range)
        }
        brackets = next
        for mark in next { storage.addAttribute(.backgroundColor, value: mark.color, range: mark.range) }
        storage.endEditing()
    }

    private func highlight(_ storage: NSTextStorage, in range: NSRange) {
        storage.setAttributes(baseAttributes, range: range)
        for token in LaTeXSyntax.tokens(in: storage.string, language: language, range: range) {
            storage.addAttributes(attributes(for: token.kind), range: token.range)
        }
        // The edit may have moved the marked brackets (outside `range` too); the next selection
        // change marks them again.
        if !brackets.isEmpty { storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length)) }
        brackets = []
    }

    private func attributes(for kind: LaTeXToken.Kind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .command, .entryType: [.foregroundColor: EditorColor.systemPurple]
        case .environment, .field: [.foregroundColor: EditorColor.systemTeal]
        case .argument: [.foregroundColor: EditorColor.systemOrange]
        case .heading: [.font: boldFont]
        case .math: [.foregroundColor: EditorColor.systemGreen]
        case .delimiter: [.foregroundColor: EditorColor.systemGray]
        case .comment: [.foregroundColor: EditorColor.editorSecondaryText, .font: font]
        }
    }
}
