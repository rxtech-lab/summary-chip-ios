import PDFKit
import SummaryKit
import SwiftUI

/// A compiled paper in PDFKit. A new PDF replaces the old one on the page being read, so the
/// preview stays put while the paper recompiles. References that failed their check are
/// highlighted in the bibliography; hovering one (or tapping it) shows what's wrong.
struct PaperPDFView: View {
    let data: Data
    var flaggedReferences: [PaperReference] = []
    @State private var hovered: PaperReferenceHit?

    var body: some View {
        PDFKitRepresentable(data: data, flagged: flaggedReferences, hovered: $hovered)
            .popover(item: $hovered, attachmentAnchor: .rect(.rect(hovered?.rect ?? .zero)), arrowEdge: .top) { hit in
                PaperReferencePopover(reference: hit.reference)
                    .presentationCompactAdaptation(.popover)
            }
            .sensoryFeedback(.selection, trigger: hovered?.id) { _, new in new != nil }
            .accessibilityIdentifier("paper-pdf")
    }
}

/// A highlighted reference under the pointer, at its rectangle in the PDF view.
struct PaperReferenceHit: Identifiable, Equatable {
    let reference: PaperReference
    let rect: CGRect
    var id: String { reference.key }
}

#if os(iOS)
private struct PDFKitRepresentable: UIViewRepresentable {
    let data: Data
    let flagged: [PaperReference]
    @Binding var hovered: PaperReferenceHit?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onHover = { hovered = $0 }
        PaperPDFDisplay.show(data, in: view, coordinator: context.coordinator)
        context.coordinator.highlight(flagged, in: view)
    }

    func makeCoordinator() -> PaperPDFDisplay { PaperPDFDisplay() }
}
#else
private struct PDFKitRepresentable: NSViewRepresentable {
    let data: Data
    let flagged: [PaperReference]
    @Binding var hovered: PaperReferenceHit?

    func makeNSView(context: Context) -> PDFView {
        let view = HoverPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .underPageBackgroundColor
        view.onPointer = { [weak coordinator = context.coordinator, weak view] point in
            guard let coordinator, let view else { return }
            coordinator.pointer(at: point, in: view)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onHover = { hovered = $0 }
        PaperPDFDisplay.show(data, in: view, coordinator: context.coordinator)
        context.coordinator.highlight(flagged, in: view)
    }

    func makeCoordinator() -> PaperPDFDisplay { PaperPDFDisplay() }
}

/// Reports where the mouse is (nil when it leaves), so hovering a highlight shows its popover.
private final class HoverPDFView: PDFView {
    var onPointer: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }
}
#endif

/// Remembers which PDF is shown so a re-render with the same bytes doesn't reset the view, and
/// which references are highlighted in it.
final class PaperPDFDisplay: NSObject {
    private var shown: Data?
    /// The flagged references the highlights were drawn for, and the document they're in.
    private var highlighted: [PaperReference] = []
    private weak var highlightedDocument: PDFDocument?
    private var highlights: [(page: PDFPage, bounds: CGRect, reference: PaperReference)] = []
    private var current: PaperReferenceHit?
    var onHover: ((PaperReferenceHit?) -> Void)?

    private static let highlightName = "chippy-reference-error"

    static func show(_ data: Data, in view: PDFView, coordinator: PaperPDFDisplay) {
        guard coordinator.shown != data, let document = PDFDocument(data: data) else { return }
        coordinator.shown = data
        // Keep the reader on the same page and zoom across recompiles.
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
        let scale = view.document == nil ? nil : view.scaleFactor
        let autoScales = view.autoScales
        view.document = document
        view.autoScales = autoScales
        if let scale, !autoScales {
            view.scaleFactor = scale
        }
        if let pageIndex, let page = document.page(at: min(pageIndex, max(document.pageCount - 1, 0))) {
            view.go(to: page)
        }
    }

    // MARK: Highlights

    /// Highlights each flagged reference's entry in the bibliography: found by its title's opening
    /// words, the last match (the bibliography comes last). Entries not found aren't highlighted.
    func highlight(_ flagged: [PaperReference], in view: PDFView) {
        guard let document = view.document, document !== highlightedDocument || flagged != highlighted else { return }
        for entry in highlights {
            for annotation in entry.page.annotations where annotation.userName == Self.highlightName { entry.page.removeAnnotation(annotation) }
        }
        highlights = []
        highlighted = flagged
        highlightedDocument = document
        setHovered(nil)
        for reference in flagged {
            guard let selection = reference.searchPhrases.lazy.compactMap({ document.findString($0, withOptions: [.caseInsensitive, .diacriticInsensitive]).last }).first else { continue }
            selection.extendForLineBoundaries()
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = line.bounds(for: page).insetBy(dx: -2, dy: -1)
                    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    annotation.color = PlatformColor.systemRed.withAlphaComponent(0.3)
                    annotation.userName = Self.highlightName
                    page.addAnnotation(annotation)
                    highlights.append((page, bounds, reference))
                }
            }
        }
    }

    /// The highlight at `point` (in the view), with its rectangle in SwiftUI's coordinates.
    private func hit(at point: CGPoint, in view: PDFView) -> PaperReferenceHit? {
        guard let page = view.page(for: point, nearest: false) else { return nil }
        let onPage = view.convert(point, to: page)
        guard let entry = highlights.first(where: { $0.page == page && $0.bounds.contains(onPage) }) else { return nil }
        // Every line of the entry together, so the popover points at the whole entry.
        let lines = highlights.filter { $0.page == page && $0.reference.key == entry.reference.key }.map(\.bounds)
        var rect = view.convert(lines.dropFirst().reduce(lines[0]) { $0.union($1) }, from: page)
        #if os(macOS)
        if !view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
        #endif
        return PaperReferenceHit(reference: entry.reference, rect: rect)
    }

    func pointer(at point: CGPoint?, in view: PDFView) {
        setHovered(point.flatMap { hit(at: $0, in: view) })
    }

    private func setHovered(_ hit: PaperReferenceHit?) {
        guard hit?.id != current?.id else { return }
        current = hit
        onHover?(hit)
    }

    #if os(iOS)
    /// A pointer hovering (iPad) or a tap shows the popover; a tap elsewhere hides it.
    func attach(to view: PDFView) {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(hover)
        view.addGestureRecognizer(tap)
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard let view = recognizer.view as? PDFView else { return }
        switch recognizer.state {
        case .began, .changed: pointer(at: recognizer.location(in: view), in: view)
        default: pointer(at: nil, in: view)
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view as? PDFView else { return }
        pointer(at: recognizer.location(in: view), in: view)
    }
    #endif
}

#if os(iOS)
extension PaperPDFDisplay: UIGestureRecognizerDelegate {
    /// PDFKit's own taps (links, selection) keep working.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif
