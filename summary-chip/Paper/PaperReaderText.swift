import SummaryKit
import SwiftUI

/// A passage of the reader with a review on it, marked in the text; tapping it opens the review.
struct PaperReviewHighlight: Hashable {
    let reviewID: String
    let quote: String
    let status: PaperReviewStatus
}

/// A paragraph of the reader. On iOS it is a text view, so the reader can select a passage and
/// choose **Add Review** in the selection menu; on the Mac the text is selectable as a whole.
struct PaperParagraphView: View {
    let spans: [PaperSpan]
    let alignment: PaperAlignment
    let context: PaperReaderContext

    var body: some View {
        PaperReviewableText(spans: spans, alignment: alignment, context: context)
    }
}

/// Reader text that takes reviews: paragraphs, the title, headings and captions. On iOS it is a
/// text view whose selection menu offers **Add Review** and that marks reviewed passages.
struct PaperReviewableText: View {
    let spans: [PaperSpan]
    var scale: CGFloat = 1
    var style: PaperTextStyle = []
    var alignment: PaperAlignment = .leading
    /// Space between lines as a share of the font size: paragraphs breathe, titles stay tight.
    var lineSpacing: CGFloat = 0.3
    var identifier = "paper-reader-paragraph"
    let context: PaperReaderContext

    var body: some View {
        #if canImport(UIKit)
        PaperSelectableText(
            text: context.nsText(spans, scale: scale, style: style),
            alignment: alignment.nsText,
            lineSpacing: context.fontSize * scale * lineSpacing,
            highlights: context.reviewHighlights,
            onReview: context.addReview,
            onOpenReview: context.openReview,
            identifier: identifier
        )
        .frame(maxWidth: .infinity, alignment: alignment.frame)
        #else
        Text(context.text(spans, scale: scale, style: style))
            .lineSpacing(context.fontSize * scale * lineSpacing)
            .multilineTextAlignment(alignment.text)
            .frame(maxWidth: .infinity, alignment: alignment.frame)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

extension PaperAlignment {
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

#if canImport(UIKit)
import UIKit

extension PaperAlignment {
    var nsText: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }
}

extension PaperReaderContext {
    /// The reader's font as UIKit sees it, for text views.
    func uiFont(_ scale: CGFloat = 1, style: PaperTextStyle = []) -> UIFont {
        let size = fontSize * scale
        let design: UIFontDescriptor.SystemDesign = style.contains(.monospace) ? .monospaced : style.contains(.sansSerif) || !serif ? .default : .serif
        var descriptor = UIFont.systemFont(ofSize: size, weight: style.contains(.bold) ? .bold : .regular).fontDescriptor
        descriptor = descriptor.withDesign(design) ?? descriptor
        var traits = descriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        if style.contains(.smallCaps) {
            let features: [[UIFontDescriptor.FeatureKey: Int]] = [[.type: kLowerCaseType, .selector: kLowerCaseSmallCapsSelector]]
            descriptor = descriptor.addingAttributes([.featureSettings: features])
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private func uiMathFont(_ font: MathFont, size: CGFloat) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size, weight: font == .bold || font == .boldItalic ? .bold : .regular).fontDescriptor
        descriptor = descriptor.withDesign(.serif) ?? descriptor
        var traits = descriptor.symbolicTraits
        if font == .italic || font == .boldItalic { traits.insert(.traitItalic) }
        if font == .bold || font == .boldItalic { traits.insert(.traitBold) }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        return UIFont(descriptor: descriptor, size: size)
    }

    /// `text(_:)` for a text view: the same runs, with UIKit fonts and the reader's links.
    func nsText(_ spans: [PaperSpan], scale: CGFloat = 1, style extra: PaperTextStyle = []) -> NSAttributedString {
        let size = fontSize * scale
        let result = NSMutableAttributedString()
        for span in spans {
            let style = span.style.union(baseStyle).union(extra)
            switch span.kind {
            case .text(let text):
                result.append(styled(text, style, scale: scale))
            case .math(let nodes, _):
                for run in PaperMath.runs(nodes) {
                    let font: MathFont = style.contains(.bold) ? (run.font == .italic ? .boldItalic : .bold) : run.font
                    var attributes: [NSAttributedString.Key: Any] = [.font: uiMathFont(font, size: size * run.scale), .foregroundColor: UIColor.label]
                    if run.baseline != 0 { attributes[.baselineOffset] = run.baseline * size }
                    result.append(NSAttributedString(string: run.text, attributes: attributes))
                }
            case .link(let label, let url):
                result.append(styled(label, style, scale: scale, link: URL(string: url)))
            case .citation(let keys, let form, let note):
                result.append(styled(document.citationText(keys, form: form, note: note), style, scale: scale, link: PaperReaderLink.citation(keys).url))
            case .reference(let key, let form):
                result.append(styled(document.referenceText(key, form: form), style, scale: scale, link: PaperReaderLink.reference(key).url))
            case .footnote(let number):
                var attributes: [NSAttributedString.Key: Any] = [.font: uiFont(scale * 0.65), .baselineOffset: size * 0.35, .foregroundColor: UIColor.label]
                if let url = PaperReaderLink.footnote(number).url { attributes[.link] = url }
                result.append(NSAttributedString(string: "\(number)", attributes: attributes))
            case .lineBreak:
                result.append(NSAttributedString(string: "\n", attributes: [.font: uiFont(scale)]))
            }
        }
        return result
    }

    private func styled(_ text: String, _ style: PaperTextStyle, scale: CGFloat, link: URL? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: uiFont(scale, style: style), .foregroundColor: UIColor.label]
        if style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link { attributes[.link] = link }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

/// A non-scrolling text view sized to its text, whose selection menu offers **Add Review**.
struct PaperSelectableText: UIViewRepresentable {
    let text: NSAttributedString
    let alignment: NSTextAlignment
    let lineSpacing: CGFloat
    let highlights: [PaperReviewHighlight]
    let onReview: ((String) -> Void)?
    var onOpenReview: ((String) -> Void)?
    var identifier = "paper-reader-paragraph"
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PaperReviewTextView {
        let view = PaperReviewTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.addReviewTap()
        return view
    }

    func updateUIView(_ view: PaperReviewTextView, context: Context) {
        context.coordinator.openURL = openURL
        view.onReview = onReview
        view.onOpenReview = onOpenReview
        view.accessibilityIdentifier = identifier
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = lineSpacing
        let styled = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: styled.length)
        styled.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        let plain = styled.string as NSString
        var reviewed: [(range: NSRange, reviewID: String)] = []
        for highlight in highlights {
            var search = whole
            while search.length > 0 {
                let found = plain.range(of: highlight.quote, options: [], range: search)
                guard found.location != NSNotFound else { break }
                styled.addAttribute(.backgroundColor, value: Self.color(for: highlight.status), range: found)
                reviewed.append((range: found, reviewID: highlight.reviewID))
                let next = found.location + max(found.length, 1)
                search = NSRange(location: next, length: whole.length - next)
            }
        }
        if view.attributedText?.isEqual(to: styled) != true {
            view.attributedText = styled
        }
        view.reviewed = onOpenReview == nil ? [] : reviewed
        // VoiceOver can't tap a passage, so each reviewed one is an action on the paragraph.
        view.accessibilityCustomActions = view.reviewed.map { passage in
            let quote = plain.substring(with: passage.range)
            return UIAccessibilityCustomAction(name: String(localized: "Open Review of “\(quote)”")) { [weak view] _ in
                view?.onOpenReview?(passage.reviewID)
                return true
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PaperReviewTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 10_000
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ceil(fitted.width), height: ceil(fitted.height))
    }

    private static func color(for status: PaperReviewStatus) -> UIColor {
        switch status {
        case .open: UIColor.systemYellow.withAlphaComponent(0.35)
        case .addressed: UIColor.systemGreen.withAlphaComponent(0.3)
        case .resolved: UIColor.clear
        }
    }

    /// Links go to the reader (citations, references, footnotes), not the system.
    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction?

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            // No link preview: the reader's own links aren't web pages.
            if case .link(let url) = textItem.content, PaperReaderLink(url) != nil { return nil }
            return .init(menu: defaultMenu)
        }
    }
}

/// A text view whose selection menu starts with **Add Review** when the reader takes reviews,
/// and where tapping a reviewed passage opens its review.
final class PaperReviewTextView: UITextView {
    var onReview: ((String) -> Void)?
    var onOpenReview: ((String) -> Void)?
    /// The marked passages and the review each belongs to.
    var reviewed: [(range: NSRange, reviewID: String)] = []
    /// Its own object: the text view is already the delegate of its scrolling recognizers.
    private let reviewTapDelegate = ReviewTapDelegate()

    func addReviewTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedReview(_:)))
        reviewTapDelegate.textView = self
        tap.delegate = reviewTapDelegate
        addGestureRecognizer(tap)
    }

    @objc private func tappedReview(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let onOpenReview, let id = review(at: recognizer.location(in: self)) else { return }
        selectedTextRange = nil
        onOpenReview(id)
    }

    /// The review whose passage is drawn under `point`, if any.
    fileprivate func review(at point: CGPoint) -> String? {
        for passage in reviewed {
            guard let start = position(from: beginningOfDocument, offset: passage.range.location),
                  let end = position(from: start, offset: passage.range.length),
                  let range = textRange(from: start, to: end) else { continue }
            if selectionRects(for: range).contains(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
                return passage.reviewID
            }
        }
        return nil
    }

    override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let onReview, let selected = text(in: textRange)?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty else {
            return super.editMenu(for: textRange, suggestedActions: suggestedActions)
        }
        let review = UIAction(title: String(localized: "Add Review"), image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { [weak self] _ in
            self?.selectedTextRange = nil
            onReview(selected)
        }
        var children: [UIMenuElement] = [review]
        children += suggestedActions
        return UIMenu(children: children)
    }
}
/// Lets the review tap begin only on a reviewed passage, alongside the text view's own taps.
private final class ReviewTapDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var textView: PaperReviewTextView?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let textView, textView.onOpenReview != nil else { return false }
        return textView.review(at: gestureRecognizer.location(in: textView)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// A double tap still selects a word in a reviewed passage instead of opening its review.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 && other.view === textView
    }
}
#endif
