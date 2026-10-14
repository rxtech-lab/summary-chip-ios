#if os(macOS)
import AppKit
import SummaryKit
import SwiftUI

extension PaperReaderContext {
    /// The reader's font as AppKit sees it, for text views.
    func platformFont(_ scale: CGFloat = 1, style: PaperTextStyle = []) -> NSFont {
        let size = fontSize * scale
        let design: NSFontDescriptor.SystemDesign = style.contains(.monospace) ? .monospaced : style.contains(.sansSerif) || !serif ? .default : .serif
        var descriptor = NSFont.systemFont(ofSize: size, weight: style.contains(.bold) ? .bold : .regular).fontDescriptor
        descriptor = descriptor.withDesign(design) ?? descriptor
        var traits = descriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.bold) }
        if style.contains(.italic) { traits.insert(.italic) }
        descriptor = descriptor.withSymbolicTraits(traits)
        if style.contains(.smallCaps) {
            let features: [[NSFontDescriptor.FeatureKey: Int]] = [[.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]]
            descriptor = descriptor.addingAttributes([.featureSettings: features])
        }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }

    func platformMathFont(_ font: MathFont, size: CGFloat) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: font == .bold || font == .boldItalic ? .bold : .regular).fontDescriptor
        descriptor = descriptor.withDesign(.serif) ?? descriptor
        var traits = descriptor.symbolicTraits
        if font == .italic || font == .boldItalic { traits.insert(.italic) }
        if font == .bold || font == .boldItalic { traits.insert(.bold) }
        descriptor = descriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }
}

/// A non-scrolling text view sized to its text, whose context menu offers **Add Review** for the
/// selected passage, and where clicking a reviewed passage opens its review.
struct PaperSelectableText: NSViewRepresentable {
    let text: NSAttributedString
    let alignment: NSTextAlignment
    let lineSpacing: CGFloat
    let highlights: [PaperReviewHighlight]
    let onReview: ((String) -> Void)?
    var onOpenReview: ((String) -> Void)?
    var identifier = "paper-reader-paragraph"
    @Environment(\.openURL) private var openURL
    @Environment(\.paperShowNote) private var showNote

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PaperReviewTextView {
        let view = PaperReviewTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: PaperReviewTextView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.showNote = showNote
        view.onReview = onReview
        view.onOpenReview = onOpenReview
        view.setAccessibilityIdentifier(identifier)
        let (styled, reviewed) = PaperReviewHighlight.mark(highlights, in: text, alignment: alignment, lineSpacing: lineSpacing)
        let plain = styled.string as NSString
        if view.textStorage?.isEqual(to: styled) != true {
            view.textStorage?.setAttributedString(styled)
        }
        view.reviewed = onOpenReview == nil ? [] : reviewed
        view.window?.invalidateCursorRects(for: view)
        // VoiceOver can't click a passage, so each reviewed one is an action on the paragraph.
        view.setAccessibilityCustomActions(view.reviewed.map { passage in
            let quote = plain.substring(with: passage.range)
            return NSAccessibilityCustomAction(name: String(localized: "Open Review of “\(quote)”")) { [weak view] in
                view?.onOpenReview?(passage.reviewID)
                return true
            }
        })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PaperReviewTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 10_000
        let fitted = nsView.fittingSize(width: width)
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ceil(fitted.width), height: ceil(fitted.height))
    }

    /// Links go to the reader, not the system: citations and footnotes open a popover by the
    /// link, references scroll the reader.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?
        var showNote: ((PaperReaderNote, CGRect) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            if let note = PaperReaderLink(url)?.note, let showNote, let textView = textView as? PaperReviewTextView {
                showNote(note, textView.linkRect(at: charIndex))
                return true
            }
            guard let openURL else { return false }
            openURL(url)
            return true
        }
    }
}

/// A text view whose context menu starts with **Add Review** when the reader takes reviews and a
/// passage is selected, and where clicking a reviewed passage opens its review.
final class PaperReviewTextView: NSTextView {
    var onReview: ((String) -> Void)?
    var onOpenReview: ((String) -> Void)?
    /// The marked passages and the review each belongs to.
    var reviewed: [(range: NSRange, reviewID: String)] = []

    /// The text's size at `width`, laid out by this view's own layout manager.
    func fittingSize(width: CGFloat) -> CGSize {
        guard let layoutManager, let textContainer else { return .zero }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).size
    }

    /// Each paragraph is its own text view: selecting in another one clears this one's selection,
    /// so only one passage ever looks selected.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = event.clickCount == 1 ? review(at: point) : nil
        // The text view tracks the mouse until it's released, selecting as it drags.
        super.mouseDown(with: event)
        guard let hit, let onOpenReview, selectedRange().length == 0 else { return }
        onOpenReview(hit)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let selected = (string as NSString).substring(with: selectedRange()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard onReview != nil, !selected.isEmpty else { return menu }
        let item = NSMenuItem(title: String(localized: "Add Review"), action: #selector(addReview(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
        item.representedObject = selected
        item.setAccessibilityIdentifier("paper-reader-add-review")
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func addReview(_ sender: NSMenuItem) {
        guard let quote = sender.representedObject as? String else { return }
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        onReview?(quote)
    }

    /// Reviewed passages show the pointing hand: a click opens their review.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard onOpenReview != nil else { return }
        for passage in reviewed {
            for rect in rects(for: passage.range) { addCursorRect(rect, cursor: .pointingHand) }
        }
    }

    /// The review whose passage is drawn under `point`, if any; links keep their own click.
    private func review(at point: CGPoint) -> String? {
        guard onOpenReview != nil else { return nil }
        let index = characterIndexForInsertion(at: point)
        if index < (textStorage?.length ?? 0), textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil { return nil }
        return reviewed.first { passage in
            rects(for: passage.range).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }?.reviewID
    }

    /// Where the link at `index` is drawn: its first line, which the popover points at.
    func linkRect(at index: Int) -> CGRect {
        var range = NSRange(location: index, length: 1)
        if index < (textStorage?.length ?? 0) { _ = textStorage?.attribute(.link, at: index, effectiveRange: &range) }
        return rects(for: range).first ?? bounds
    }

    /// Where a passage is drawn, line by line, in the view's coordinates.
    private func rects(for range: NSRange) -> [CGRect] {
        guard let layoutManager, let textContainer else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var rects: [CGRect] = []
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }
}

extension EnvironmentValues {
    /// Shows a citation or footnote in a popover pointing at a rect of the clicked view.
    @Entry var paperShowNote: ((PaperReaderNote, CGRect) -> Void)?
}

/// Citations and footnotes in the reader's text open in a popover by the link instead of a sheet.
/// Text views point it at the link; SwiftUI text (table cells, subfigure captions) at the whole text.
struct PaperNotePopover: ViewModifier {
    let context: PaperReaderContext
    @State private var note: PaperReaderNote?
    @State private var anchor: CGRect?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .environment(\.paperShowNote) { note, rect in
                anchor = rect
                self.note = note
            }
            .environment(\.openURL, OpenURLAction { url in
                guard let note = PaperReaderLink(url)?.note else {
                    openURL(url)
                    return .handled
                }
                anchor = nil
                self.note = note
                return .handled
            })
            .popover(item: $note, attachmentAnchor: anchor.map { .rect(.rect($0)) } ?? .rect(.bounds), arrowEdge: .bottom) { note in
                ViewThatFits(in: .vertical) {
                    PaperReaderNoteView(note: note, context: context)
                    ScrollView { PaperReaderNoteView(note: note, context: context) }
                }
                .frame(width: 380)
                .frame(maxHeight: 440)
                .accessibilityIdentifier("paper-reader-note")
            }
    }
}
#endif
