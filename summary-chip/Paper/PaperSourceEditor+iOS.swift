#if os(iOS)
import SummaryKit
import SwiftUI
import UIKit

struct PlatformSourceEditor: UIViewRepresentable {
    @Binding var text: String
    let fileID: String
    let language: LaTeXLanguage
    let isEditable: Bool
    let jump: PaperLineJump?
    let issues: [PaperEditorIssue]
    let symbols: () -> LaTeXSymbols
    var onImageDrop: (([NSItemProvider]) -> Bool)?

    func makeUIView(context: Context) -> PaperUITextView {
        let view = PaperUITextView.make()
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.delegate = context.coordinator
        view.textDropDelegate = context.coordinator
        view.textStorage.delegate = context.coordinator.highlighter
        view.typingAttributes = context.coordinator.highlighter.baseAttributes
        view.setUp()
        context.coordinator.attachBar(to: view)
        return view
    }

    func updateUIView(_ view: PaperUITextView, context: Context) {
        let coordinator = context.coordinator
        let state = coordinator.state
        state.onChange = { text = $0 }
        state.symbols = symbols
        view.symbols = symbols
        view.isEditable = isEditable
        view.onImageDrop = isEditable ? onImageDrop : nil
        view.issues = issues
        if state.fileID != fileID {
            state.fileID = fileID
            coordinator.highlighter.language = language
            view.language = language
            view.text = text
            view.selectedRange = NSRange(location: 0, length: 0)
            view.undoManager?.removeAllActions()
            view.setContentOffset(.zero, animated: false)
        } else if view.text != text {
            // Changed elsewhere (an agent's edit merged in): keep the cursor where it was.
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
        if let jump, state.jumpID != jump.id {
            state.jumpID = jump.id
            let target = paperRange(ofLine: jump.line, in: view.text as NSString)
            view.selectedRange = target
            view.scrollRangeToVisible(target)
            if isEditable { view.becomeFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate, UITextDropDelegate {
        let state = PaperSourceEditorState()
        let highlighter = LaTeXHighlighter(fontSize: 15)
        private let bar = PaperCompletionBar()
        private var completion: LaTeXCompletionContext?

        func attachBar(to view: PaperUITextView) {
            view.inputAccessoryView = bar
            bar.onPick = { [weak self, weak view] suggestion in
                guard let self, let view else { return }
                pick(suggestion, in: view)
            }
            bar.onKey = { [weak view] key in view?.insertText(key) }
        }

        func textViewDidChange(_ textView: UITextView) {
            state.onChange?(textView.textStorage.string)
            (textView as? PaperUITextView)?.textDidChange()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let view = textView as? PaperUITextView else { return }
            let selection = view.selectedRange
            highlighter.markBrackets(at: selection.length == 0 ? selection.location : nil, in: view.textStorage)
            view.selectionDidChange()
            refreshBar(view)
        }

        /// Completions for the word at the caret; otherwise the caret line's error or the caret
        /// word's description. Nothing while composing (marked text) or selecting.
        private func refreshBar(_ view: PaperUITextView) {
            let text = view.textStorage.string
            let selection = view.selectedRange
            let isTyping = view.markedTextRange == nil && selection.length == 0
            completion = isTyping && highlighter.language == .tex ? LaTeXCompletion.context(in: text, at: selection.location) : nil
            let suggestions = completion.map { LaTeXCompletion.suggestions(for: $0, in: text, symbols: state.symbols()) } ?? []
            var info: PaperCompletionBar.Info?
            if suggestions.isEmpty, isTyping {
                if let error = view.issuesByLine[view.lineIndex.line(at: selection.location)]?.first {
                    info = PaperCompletionBar.Info(text: error, isError: true)
                } else if highlighter.language != .plain {
                    let word = [selection.location - 1, selection.location].lazy
                        .compactMap { LaTeXInfo.info(in: text, at: $0, symbols: self.state.symbols()) }.first
                    info = word.map { PaperCompletionBar.Info(text: "\($0.title) — \($0.detail)", isError: $0.isProblem) }
                }
            }
            bar.show(suggestions, info: info)
        }

        private func pick(_ suggestion: LaTeXSuggestion, in view: PaperUITextView) {
            guard let completion else { return }
            view.apply(LaTeXCompletion.edit(applying: suggestion, kind: completion.kind, replacing: completion.range, in: view.textStorage.string))
        }
    }
}

/// The iOS editor's text view: a gutter with line numbers, compile errors drawn over their lines,
/// brace pairing while typing, and hover cards for an iPad pointer.
final class PaperUITextView: UITextView {
    var language: LaTeXLanguage = .plain
    var symbols: () -> LaTeXSymbols = { LaTeXSymbols() }
    var onImageDrop: (([NSItemProvider]) -> Bool)?
    var issues: [PaperEditorIssue] = [] {
        didSet {
            guard issues != oldValue else { return }
            issuesByLine = issues.byLine
            overlay.setNeedsDisplay()
        }
    }

    private(set) var issuesByLine: [Int: [String]] = [:]
    /// A text view built on a hand-made TextKit 1 stack doesn't keep its text storage alive.
    private var ownedStorage: NSTextStorage?
    private let overlay = PaperEditorOverlay()
    private var cachedLineIndex: LaTeXLineIndex?
    private var gutterWidth: CGFloat = 0
    private var hoverCard: UIView?
    private var hoverTarget: PaperHoverTarget?
    private var hoverTask: Task<Void, Never>?

    /// TextKit 1, for the line geometry the gutter and the error pills are drawn from. Built by hand:
    /// `init(usingTextLayoutManager:)` skips this subclass's property initializers.
    static func make() -> PaperUITextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = PaperUITextView(frame: .zero, textContainer: container)
        view.ownedStorage = storage
        return view
    }

    var lineIndex: LaTeXLineIndex {
        if let cachedLineIndex { return cachedLineIndex }
        let index = LaTeXLineIndex(textStorage.string)
        cachedLineIndex = index
        return index
    }

    override var text: String! {
        didSet { textDidChange() }
    }

    func setUp() {
        overlay.isUserInteractionEnabled = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.contentMode = .redraw
        addSubview(overlay)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        updateGutter()
    }

    func textDidChange() {
        cachedLineIndex = nil
        hideHover()
        updateGutter()
        overlay.setNeedsDisplay()
    }

    func selectionDidChange() {
        overlay.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        bringSubviewToFront(overlay)
        if let hoverCard { bringSubviewToFront(hoverCard) }
        overlay.setNeedsDisplay()
    }

    private func updateGutter() {
        let width = PaperEditorDecorations.gutterWidth(lineCount: lineIndex.lineCount)
        guard width != gutterWidth else { return }
        gutterWidth = width
        textContainerInset = UIEdgeInsets(top: 16, left: width + 6, bottom: 80, right: 12)
    }

    // MARK: Brace pairing

    override func insertText(_ text: String) {
        if markedTextRange == nil, language != .plain,
           let edit = LaTeXBrackets.autoPair(in: textStorage.string, replacing: selectedRange, with: text) {
            apply(edit)
        } else {
            super.insertText(text)
        }
    }

    override func deleteBackward() {
        let selection = selectedRange
        if markedTextRange == nil, language != .plain, selection.length == 0, selection.location > 0,
           let edit = LaTeXBrackets.autoPair(in: textStorage.string, replacing: NSRange(location: selection.location - 1, length: 1), with: "") {
            apply(edit)
        } else {
            super.deleteBackward()
        }
    }

    /// Makes an edit as typing would (undoable), then puts the caret where it says.
    func apply(_ edit: LaTeXCompletionEdit) {
        if edit.range.length > 0 || !edit.text.isEmpty,
           let start = position(from: beginningOfDocument, offset: edit.range.location),
           let end = position(from: start, offset: edit.range.length),
           let range = textRange(from: start, to: end) {
            replace(range, withText: edit.text)
        }
        selectedRange = edit.selection
        delegate?.textViewDidChange?(self)
    }

    // MARK: Drawing

    /// Draws the gutter, error tints and pills for the visible part; called by the overlay.
    fileprivate func drawDecorations(in bounds: CGRect) {
        let inset = textContainerInset
        let visible = CGRect(x: 0, y: contentOffset.y - inset.top, width: textContainer.size.width, height: bounds.height)
        let lines = PaperEditorDecorations.visibleLines(in: visible, layoutManager: layoutManager, container: textContainer, lines: lineIndex)
        let offset = CGPoint(x: inset.left, y: inset.top - contentOffset.y)
        let errors = Set(issuesByLine.keys)
        EditorColor.editorGutter.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height))
        EditorColor.separator.setFill()
        UIRectFill(CGRect(x: gutterWidth - 1 / traitCollection.displayScale, y: 0, width: 1 / traitCollection.displayScale, height: bounds.height))
        let current = selectedRange.length == 0 && isFirstResponder ? lineIndex.line(at: selectedRange.location) : nil
        PaperEditorDecorations.drawNumbers(lines, width: gutterWidth, offset: CGPoint(x: 0, y: offset.y), errors: errors, current: current)
        PaperEditorDecorations.drawErrorTints(lines, errors: errors, x: gutterWidth, width: bounds.width - gutterWidth, offset: offset)
        PaperEditorDecorations.drawPills(lines, issues: issuesByLine, maxX: bounds.width - 8, maxWidth: (bounds.width - gutterWidth) * 0.55, offset: offset)
    }

    // MARK: Hover (iPad pointer)

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let location = recognizer.location(in: self)
            let point = CGPoint(x: location.x - textContainerInset.left, y: location.y - textContainerInset.top)
            if let hoverTarget, hoverTarget.anchor.insetBy(dx: -2, dy: -2).contains(point) { return }
            hideHover()
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                showHover(at: point)
            }
        default:
            hideHover()
        }
    }

    private func showHover(at point: CGPoint) {
        guard let target = PaperEditorDecorations.hoverTarget(
            at: point, layoutManager: layoutManager, container: textContainer, text: textStorage.string,
            lines: lineIndex, issues: issuesByLine, symbols: symbols
        ) else { return }
        let card = UIHostingConfiguration {
            PaperHoverCard(info: target.info, errors: target.errors)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8, y: 2)
        }
        .margins(.all, 0)
        .makeContentView()
        card.isUserInteractionEnabled = false
        let size = card.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        let anchor = target.anchor.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if origin.y < contentOffset.y + 4 { origin.y = anchor.maxY + 6 }
        origin.x = min(max(gutterWidth + 4, origin.x), bounds.width - size.width - 8)
        card.frame = CGRect(origin: origin, size: size)
        addSubview(card)
        hoverCard = card
        hoverTarget = target
    }

    private func hideHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverCard?.removeFromSuperview()
        hoverCard = nil
        hoverTarget = nil
    }
}

/// Draws over the text view's visible area (it's moved there on every scroll).
private final class PaperEditorOverlay: UIView {
    override func draw(_ rect: CGRect) {
        (superview as? PaperUITextView)?.drawDecorations(in: bounds)
    }
}
#endif
