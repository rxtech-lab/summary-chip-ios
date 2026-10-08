#if os(macOS)
import AppKit
import SummaryKit
import SwiftUI

struct PlatformSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let fileID: String
    let language: LaTeXLanguage
    let isEditable: Bool
    let jump: PaperLineJump?
    let issues: [PaperEditorIssue]
    let symbols: () -> LaTeXSymbols
    var onImageDrop: (([NSItemProvider]) -> Bool)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let view = PaperTextView.make(size: scroll.contentSize)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 6, height: 12)
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator.highlighter
        view.typingAttributes = context.coordinator.highlighter.baseAttributes
        scroll.documentView = view
        let ruler = PaperLineNumberRuler(textView: view)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        view.ruler = ruler
        view.observeScrolling()
        view.registerForDraggedTypes(view.registeredDraggedTypes + PaperTextView.imagePasteboardTypes)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? PaperTextView else { return }
        let state = context.coordinator.state
        state.onChange = { text = $0 }
        view.symbols = symbols
        view.isEditable = isEditable
        view.onImageDrop = isEditable ? onImageDrop : nil
        view.issues = issues
        if state.fileID != fileID {
            state.fileID = fileID
            context.coordinator.highlighter.language = language
            view.language = language
            view.string = text
            view.textDidChangeForDecorations()
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.undoManager?.removeAllActions()
            view.scroll(.zero)
        } else if view.string != text {
            // Changed elsewhere (an agent's edit merged in): keep the cursor where it was.
            let selection = view.selectedRange()
            view.string = text
            view.textDidChangeForDecorations()
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        if let jump, state.jumpID != jump.id {
            state.jumpID = jump.id
            let target = paperRange(ofLine: jump.line, in: view.string as NSString)
            view.setSelectedRange(target)
            view.scrollRangeToVisible(target)
            view.window?.makeFirstResponder(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let state = PaperSourceEditorState()
        let highlighter = LaTeXHighlighter(fontSize: 13)

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            state.onChange?(view.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? PaperTextView, let storage = view.textStorage else { return }
            let selection = view.selectedRange()
            highlighter.markBrackets(at: selection.length == 0 ? selection.location : nil, in: storage)
            view.selectionDidChange()
        }
    }
}

/// The Mac editor's text view (TextKit 1): compile errors drawn over their lines, brace pairing,
/// a completion list with descriptions that opens while typing, and hover cards.
final class PaperTextView: NSTextView {
    var symbols: () -> LaTeXSymbols = { LaTeXSymbols() }
    var onImageDrop: (([NSItemProvider]) -> Bool)?
    var language: LaTeXLanguage = .plain

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isImageDrop(sender.draggingPasteboard) { return isEditable && onImageDrop != nil ? .copy : [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isImageDrop(sender.draggingPasteboard) { return isEditable && onImageDrop != nil ? .copy : [] }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isImageDrop(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        guard isEditable, let onImageDrop else { return false }
        return onImageDrop(imageProviders(sender.draggingPasteboard))
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isImageDrop(sender.draggingPasteboard) { return isEditable && onImageDrop != nil }
        return super.prepareForDragOperation(sender)
    }
    var issues: [PaperEditorIssue] = [] {
        didSet {
            guard issues != oldValue else { return }
            issuesByLine = issues.byLine
            needsDisplay = true
            ruler?.needsDisplay = true
        }
    }

    weak var ruler: PaperLineNumberRuler?
    private(set) var issuesByLine: [Int: [String]] = [:]
    /// A text view built on a hand-made TextKit 1 stack doesn't keep its text storage alive.
    private var ownedStorage: NSTextStorage?
    private var cachedLineIndex: LaTeXLineIndex?
    private let completionPanel = PaperCompletionPanel()
    private var completion: LaTeXCompletionContext?
    private var hoverPopover: NSPopover?
    private var hoverTarget: PaperHoverTarget?
    private var hoverTask: Task<Void, Never>?

    static func make(size: NSSize) -> PaperTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let view = PaperTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        view.ownedStorage = storage
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.completionPanel.onPick = { [weak view] suggestion in view?.accept(suggestion) }
        return view
    }

    var lineIndex: LaTeXLineIndex {
        if let cachedLineIndex { return cachedLineIndex }
        let index = LaTeXLineIndex(string)
        cachedLineIndex = index
        return index
    }

    func observeScrolling() {
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func didScroll() {
        completionPanel.hide()
        hideHover()
        ruler?.needsDisplay = true
    }

    func textDidChangeForDecorations() {
        cachedLineIndex = nil
        ruler?.updateThickness()
        ruler?.needsDisplay = true
    }

    func selectionDidChange() {
        ruler?.needsDisplay = true
        // Clicking or arrowing away from the word closes the list.
        if completionPanel.isShown {
            refreshCompletions()
            if completion == nil { completionPanel.hide() }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        textDidChangeForDecorations()
        hideHover()
        guard !hasMarkedText() else { return }
        refreshCompletions()
        if let completion, completion.kind != .command || !completion.prefix.isEmpty {
            showCompletions()
        } else {
            completionPanel.hide()
        }
    }

    override func resignFirstResponder() -> Bool {
        completionPanel.hide()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            completionPanel.hide()
            hideHover()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Brace pairing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if let typed = string as? String, !hasMarkedText(), language != .plain,
           let edit = LaTeXBrackets.autoPair(in: self.string, replacing: range, with: typed) {
            apply(edit)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if !hasMarkedText(), language != .plain, selection.length == 0, selection.location > 0,
           let edit = LaTeXBrackets.autoPair(in: string, replacing: NSRange(location: selection.location - 1, length: 1), with: "") {
            apply(edit)
        } else {
            super.deleteBackward(sender)
        }
    }

    private func apply(_ edit: LaTeXCompletionEdit) {
        if edit.range.length > 0 || !edit.text.isEmpty {
            super.insertText(edit.text, replacementRange: edit.range)
        }
        setSelectedRange(edit.selection)
    }

    // MARK: Completion

    /// Arrows, Return, Tab and Esc drive the list while it's open; Esc (or ⌥Esc) opens it.
    override func doCommand(by selector: Selector) {
        if completionPanel.isShown {
            switch selector {
            case #selector(moveUp(_:)): return completionPanel.moveSelection(by: -1)
            case #selector(moveDown(_:)): return completionPanel.moveSelection(by: 1)
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if let suggestion = completionPanel.model.selected { return accept(suggestion) }
            case #selector(cancelOperation(_:)): return completionPanel.hide()
            default: break
            }
        } else if selector == #selector(cancelOperation(_:)) || selector == #selector(complete(_:)) {
            refreshCompletions()
            if completion != nil { return showCompletions() }
        }
        super.doCommand(by: selector)
    }

    private func refreshCompletions() {
        let selection = selectedRange()
        completion = isEditable && language == .tex && selection.length == 0 ? LaTeXCompletion.context(in: string, at: selection.location) : nil
    }

    private func showCompletions() {
        guard let completion, let window else { return completionPanel.hide() }
        let suggestions = LaTeXCompletion.suggestions(for: completion, in: string, symbols: symbols())
        guard !suggestions.isEmpty else { return completionPanel.hide() }
        let caret = firstRect(forCharacterRange: completion.range, actualRange: nil)
        completionPanel.show(suggestions, below: caret, in: window)
    }

    private func accept(_ suggestion: LaTeXSuggestion) {
        completionPanel.hide()
        guard let completion else { return }
        let edit = LaTeXCompletion.edit(applying: suggestion, kind: completion.kind, replacing: completion.range, in: string)
        super.insertText(edit.text, replacementRange: edit.range)
        setSelectedRange(edit.selection)
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !issuesByLine.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let lines = visibleLines(in: rect, layoutManager: layoutManager, container: textContainer)
        PaperEditorDecorations.drawErrorTints(lines, errors: Set(issuesByLine.keys), x: 0, width: bounds.width, offset: CGPoint(x: origin.x, y: origin.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !issuesByLine.isEmpty, let layoutManager, let textContainer else { return }
        let lines = visibleLines(in: dirtyRect, layoutManager: layoutManager, container: textContainer)
        let origin = textContainerOrigin
        PaperEditorDecorations.drawPills(lines, issues: issuesByLine, maxX: bounds.width - 8, maxWidth: bounds.width * 0.5, offset: CGPoint(x: origin.x, y: origin.y))
    }

    func visibleLines(in rect: NSRect, layoutManager: NSLayoutManager, container: NSTextContainer) -> [PaperVisibleLine] {
        let origin = textContainerOrigin
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        return PaperEditorDecorations.visibleLines(in: local, layoutManager: layoutManager, container: container, lines: lineIndex)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.options.contains(.mouseMoved) { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let location = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: location.x - textContainerOrigin.x, y: location.y - textContainerOrigin.y)
        if let hoverTarget, hoverTarget.anchor.insetBy(dx: -2, dy: -2).contains(point) { return }
        hideHover()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            showHover(at: point)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideHover()
    }

    override func keyDown(with event: NSEvent) {
        hideHover()
        super.keyDown(with: event)
    }

    private func showHover(at point: CGPoint) {
        guard let layoutManager, let textContainer, !completionPanel.isShown,
              let target = PaperEditorDecorations.hoverTarget(
                at: point, layoutManager: layoutManager, container: textContainer, text: string,
                lines: lineIndex, issues: issuesByLine, symbols: symbols
              ) else { return }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PaperHoverCard(info: target.info, errors: target.errors))
        let anchor = target.anchor.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        hoverPopover = popover
        hoverTarget = target
    }

    private func hideHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverPopover?.close()
        hoverPopover = nil
        hoverTarget = nil
    }
}

/// Line numbers beside the Mac editor; lines with compile errors are numbered in red with a dot.
final class PaperLineNumberRuler: NSRulerView {
    private weak var textView: PaperTextView?

    init(textView: PaperTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func updateThickness() {
        guard let textView else { return }
        let width = PaperEditorDecorations.gutterWidth(lineCount: textView.lineIndex.lineCount)
        if ruleThickness != width { ruleThickness = width }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        EditorColor.editorGutter.setFill()
        bounds.fill()
        EditorColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        let lines = textView.visibleLines(in: textView.visibleRect, layoutManager: layoutManager, container: container)
        // Container coordinates to the ruler's.
        let origin = convert(NSPoint(x: 0, y: textView.textContainerOrigin.y), from: textView)
        let selection = textView.selectedRange()
        let current = selection.length == 0 ? textView.lineIndex.line(at: selection.location) : nil
        PaperEditorDecorations.drawNumbers(lines, width: ruleThickness, offset: CGPoint(x: 0, y: origin.y), errors: Set(textView.issuesByLine.keys), current: current)
    }
}
#endif
