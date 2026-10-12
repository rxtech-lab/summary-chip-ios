import SummaryKit
import SwiftUI

/// A display formula laid out natively: fractions stacked, scripts raised, roots and delimiters
/// drawn to fit what they enclose. Pieces line up on the math axis, as TeX sets them.
struct PaperMathView: View {
    let nodes: [MathNode]
    let size: CGFloat
    var display = true

    var body: some View {
        MathListView(nodes: nodes, size: size, display: display, level: 0)
            .fixedSize()
    }
}

extension VerticalAlignment {
    private nonisolated enum MathAxis: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    /// Where fraction bars sit: the middle of the line's lowercase letters.
    nonisolated static let mathAxis = VerticalAlignment(MathAxis.self)
}

enum PaperMathFont {
    static func font(_ font: MathFont, size: CGFloat) -> Font {
        let base = Font.system(size: size, design: .serif)
        return switch font {
        case .italic: base.italic()
        case .upright: base
        case .bold: base.bold()
        case .boldItalic: base.bold().italic()
        }
    }
}

/// A row of nodes; runs of letters in one font share one text.
private struct MathListView: View {
    let nodes: [MathNode]
    let size: CGFloat
    let display: Bool
    let level: Int

    var body: some View {
        MathRowLayout {
            ForEach(Array(Self.pieces(nodes).enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let text, let font):
                    Text(text).font(PaperMathFont.font(font, size: size)).fixedSize()
                case .node(let node):
                    MathNodeView(node: node, size: size, display: display, level: level)
                }
            }
        }
    }

    enum Piece {
        case text(String, MathFont)
        case node(MathNode)
    }

    static func pieces(_ nodes: [MathNode]) -> [Piece] {
        var pieces: [Piece] = []
        for node in nodes {
            if case .symbol(let text, let font) = node {
                if case .text(let previous, let previousFont)? = pieces.last, previousFont == font {
                    pieces[pieces.count - 1] = .text(previous + text, font)
                } else {
                    pieces.append(.text(text, font))
                }
            } else {
                pieces.append(.node(node))
            }
        }
        return pieces
    }
}

private struct MathNodeView: View {
    let node: MathNode
    let size: CGFloat
    let display: Bool
    let level: Int

    private var scriptSize: CGFloat { max(size * 0.7, 9) }

    var body: some View {
        switch node {
        case .symbol(let text, let font):
            Text(text).font(PaperMathFont.font(font, size: size)).fixedSize()
        case .operation(let text, let spacing):
            let padding: CGFloat = level > 0 ? 0.05 : spacing == .relation ? 0.28 : spacing == .binary ? 0.22 : 0
            Text(text).font(PaperMathFont.font(.upright, size: size)).fixedSize()
                .padding(.leading, spacing == .punctuation ? 0 : padding * size)
                .padding(.trailing, spacing == .punctuation ? 0.17 * size : padding * size)
        case .largeOperator(let text, _):
            let isSymbol = text.count == 1
            Text(text).font(PaperMathFont.font(.upright, size: isSymbol && display ? size * 1.45 : size)).fixedSize()
                .padding(.horizontal, isSymbol ? 0.08 * size : 0.05 * size)
        case .text(let text):
            Text(text).font(PaperMathFont.font(.upright, size: size)).fixedSize()
        case .space(let em):
            Color.clear.frame(width: max(em * size, 0), height: 1)
        case .fraction(let numerator, let denominator, let line):
            let partSize = display ? size : max(size * 0.8, 9)
            MathFractionLayout(size: size) {
                MathListView(nodes: numerator, size: partSize, display: false, level: level)
                Rectangle().fill(line ? Color.primary : Color.clear)
                MathListView(nodes: denominator, size: partSize, display: false, level: level)
            }
        case .scripts(let base, let superscript, let subscript):
            scripts(base: base, superscript: superscript, subscript: subscript)
        case .radical(let inner, let index):
            MathRadicalLayout(size: size, hasIndex: index != nil) {
                MathListView(nodes: inner, size: size, display: display, level: level)
                RadicalShape(signWidth: 0.55 * size).stroke(Color.primary, style: StrokeStyle(lineWidth: max(size * 0.05, 1), lineJoin: .round))
                if let index { MathListView(nodes: index, size: max(size * 0.55, 8), display: false, level: level + 1) }
            }
        case .accent(let inner, let accent):
            MathAccentLayout(size: size, below: accent == .underline) {
                MathListView(nodes: inner, size: size, display: display, level: level)
                accentMark(accent)
            }
        case .fenced(let open, let inner, let close):
            MathFenceLayout(size: size) {
                DelimiterShape(delimiter: open).stroke(Color.primary, style: StrokeStyle(lineWidth: max(size * 0.05, 1), lineCap: .round, lineJoin: .round))
                MathListView(nodes: inner, size: size, display: display, level: level)
                DelimiterShape(delimiter: close).stroke(Color.primary, style: StrokeStyle(lineWidth: max(size * 0.05, 1), lineCap: .round, lineJoin: .round))
            }
        case .table(let rows, let style):
            table(rows, style: style)
        }
    }

    @ViewBuilder
    private func scripts(base: [MathNode], superscript: [MathNode]?, subscript: [MathNode]?) -> some View {
        if display, base.count == 1, case .largeOperator(_, true) = base[0] {
            MathLimitsLayout(size: size, hasAbove: superscript != nil, hasBelow: subscript != nil) {
                MathListView(nodes: base, size: size, display: display, level: level)
                if let superscript { MathListView(nodes: superscript, size: scriptSize, display: false, level: level + 1) }
                if let subscript { MathListView(nodes: subscript, size: scriptSize, display: false, level: level + 1) }
            }
        } else {
            MathScriptsLayout(size: size, hasSuperscript: superscript != nil, hasSubscript: subscript != nil) {
                MathListView(nodes: base, size: size, display: display, level: level)
                if let superscript { MathListView(nodes: superscript, size: scriptSize, display: false, level: level + 1) }
                if let subscript { MathListView(nodes: subscript, size: scriptSize, display: false, level: level + 1) }
            }
        }
    }

    @ViewBuilder
    private func accentMark(_ accent: MathAccent) -> some View {
        switch accent {
        case .bar, .underline:
            Rectangle().fill(Color.primary).frame(height: max(size * 0.05, 1))
        case .vector:
            Text("→").font(.system(size: size * 0.6)).fixedSize()
        default:
            Text(Self.glyph(accent)).font(PaperMathFont.font(.upright, size: size)).fixedSize()
        }
    }

    private static func glyph(_ accent: MathAccent) -> String {
        switch accent {
        case .hat: "ˆ"
        case .tilde: "˜"
        case .dot: "˙"
        default: "¨"
        }
    }

    private func table(_ rows: [[[MathNode]]], style: MathTableStyle) -> some View {
        Grid(horizontalSpacing: style == .cases ? size : style == .aligned ? 0 : size * 0.8, verticalSpacing: size * 0.3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        MathListView(nodes: cell, size: size, display: display, level: level)
                            .gridColumnAlignment(style == .matrix ? .center : style == .cases || column % 2 == 1 ? .leading : .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, size * 0.1)
    }
}

// MARK: - Layouts

/// Places pieces side by side on their shared math axis.
private nonisolated struct MathRowLayout: Layout {
    private func metrics(_ subviews: Subviews) -> (width: CGFloat, above: CGFloat, below: CGFloat) {
        var width: CGFloat = 0, above: CGFloat = 0, below: CGFloat = 0
        for subview in subviews {
            let dimensions = subview.dimensions(in: .unspecified)
            let axis = dimensions[.mathAxis]
            width += dimensions.width
            above = max(above, axis)
            below = max(below, dimensions.height - axis)
        }
        return (width, above, below)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let metrics = metrics(subviews)
        return CGSize(width: metrics.width, height: metrics.above + metrics.below)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let above = metrics(subviews).above
        var x = bounds.minX
        for subview in subviews {
            let dimensions = subview.dimensions(in: .unspecified)
            subview.place(at: CGPoint(x: x, y: bounds.minY + above - dimensions[.mathAxis]), proposal: .unspecified)
            x += dimensions.width
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guide == .mathAxis ? bounds.minY + metrics(subviews).above : nil
    }
}

/// Numerator, bar, denominator; the bar on the axis.
private nonisolated struct MathFractionLayout: Layout {
    let size: CGFloat
    private var gap: CGFloat { size * 0.12 }
    private var thickness: CGFloat { max(size * 0.05, 1) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let top = subviews[0].sizeThatFits(.unspecified), bottom = subviews[2].sizeThatFits(.unspecified)
        return CGSize(width: max(top.width, bottom.width) + size * 0.3, height: top.height + bottom.height + 2 * gap + thickness)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let top = subviews[0].sizeThatFits(.unspecified), bottom = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.minX + size * 0.08, y: bounds.minY + top.height + gap), proposal: ProposedViewSize(width: bounds.width - size * 0.16, height: thickness))
        subviews[2].place(at: CGPoint(x: bounds.midX, y: bounds.maxY - bottom.height), anchor: .top, proposal: .unspecified)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .mathAxis else { return nil }
        return bounds.minY + subviews[0].sizeThatFits(.unspecified).height + gap + thickness / 2
    }
}

/// A base with a raised superscript and a lowered subscript after it.
private nonisolated struct MathScriptsLayout: Layout {
    let size: CGFloat
    let hasSuperscript: Bool
    let hasSubscript: Bool

    private struct Frames {
        var base: CGPoint, upper: CGPoint?, lower: CGPoint?
        var size: CGSize
        var axis: CGFloat
    }

    private func frames(_ subviews: Subviews) -> Frames {
        let base = subviews[0].dimensions(in: .unspecified)
        let axis = base[.mathAxis]
        let sup = hasSuperscript ? subviews[1].sizeThatFits(.unspecified) : nil
        let sub = hasSubscript ? subviews[hasSuperscript ? 2 : 1].sizeThatFits(.unspecified) : nil
        let supCenter = min(axis - 0.2 * size, 0.35 * size)
        var subCenter = max(axis + 0.3 * size, base.height - 0.3 * size)
        if let sup, let sub { subCenter = max(subCenter, supCenter + (sup.height + sub.height) / 2 - 0.1 * size) }
        var top: CGFloat = 0, bottom = base.height
        if let sup { top = min(top, supCenter - sup.height / 2) }
        if let sub { bottom = max(bottom, subCenter + sub.height / 2) }
        let x = base.width + size * 0.04
        let width = x + max(sup?.width ?? 0, sub?.width ?? 0)
        return Frames(
            base: CGPoint(x: 0, y: -top),
            upper: sup.map { CGPoint(x: x, y: supCenter - $0.height / 2 - top) },
            lower: sub.map { CGPoint(x: x, y: subCenter - $0.height / 2 - top) },
            size: CGSize(width: width, height: bottom - top),
            axis: axis - top
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { frames(subviews).size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(subviews)
        let origin = bounds.origin
        subviews[0].place(at: CGPoint(x: origin.x + frames.base.x, y: origin.y + frames.base.y), proposal: .unspecified)
        if let sup = frames.upper { subviews[1].place(at: CGPoint(x: origin.x + sup.x, y: origin.y + sup.y), proposal: .unspecified) }
        if let sub = frames.lower { subviews[hasSuperscript ? 2 : 1].place(at: CGPoint(x: origin.x + sub.x, y: origin.y + sub.y), proposal: .unspecified) }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guide == .mathAxis ? bounds.minY + frames(subviews).axis : nil
    }
}

/// `∑` with its limits centered above and below.
private nonisolated struct MathLimitsLayout: Layout {
    let size: CGFloat
    let hasAbove: Bool
    let hasBelow: Bool

    private func parts(_ subviews: Subviews) -> (base: ViewDimensions, above: CGSize?, below: CGSize?) {
        (subviews[0].dimensions(in: .unspecified),
         hasAbove ? subviews[1].sizeThatFits(.unspecified) : nil,
         hasBelow ? subviews[hasAbove ? 2 : 1].sizeThatFits(.unspecified) : nil)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (base, above, below) = parts(subviews)
        let width = max(base.width, above?.width ?? 0, below?.width ?? 0)
        return CGSize(width: width, height: base.height + (above?.height ?? 0) + (below?.height ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (base, above, _) = parts(subviews)
        var y = bounds.minY
        if let above {
            subviews[1].place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: .unspecified)
            y += above.height
        }
        subviews[0].place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: .unspecified)
        y += base.height
        if hasBelow { subviews[hasAbove ? 2 : 1].place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: .unspecified) }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .mathAxis else { return nil }
        let (base, above, _) = parts(subviews)
        return bounds.minY + (above?.height ?? 0) + base[.mathAxis]
    }
}

/// The radicand under a drawn root sign, with the index tucked into its crook.
private nonisolated struct MathRadicalLayout: Layout {
    let size: CGFloat
    let hasIndex: Bool
    private var signWidth: CGFloat { size * 0.55 }
    private var topPadding: CGFloat { size * 0.15 }

    private func indexWidth(_ subviews: Subviews) -> CGFloat {
        hasIndex ? max(subviews[2].sizeThatFits(.unspecified).width - signWidth * 0.4, 0) : 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let inner = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: indexWidth(subviews) + signWidth + inner.width + size * 0.1, height: inner.height + topPadding)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offset = indexWidth(subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX + offset + signWidth, y: bounds.minY + topPadding), proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.minX + offset, y: bounds.minY + size * 0.04), proposal: ProposedViewSize(width: bounds.width - offset, height: bounds.height - size * 0.04))
        if hasIndex {
            let index = subviews[2].sizeThatFits(.unspecified)
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + bounds.height * 0.55 - index.height), proposal: .unspecified)
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guide == .mathAxis ? bounds.minY + topPadding + subviews[0].dimensions(in: .unspecified)[.mathAxis] : nil
    }
}

/// A mark centered over (or a line under) its base.
private nonisolated struct MathAccentLayout: Layout {
    let size: CGFloat
    let below: Bool

    private func lift(_ subviews: Subviews) -> CGFloat {
        let mark = subviews[1].sizeThatFits(ProposedViewSize(width: subviews[0].sizeThatFits(.unspecified).width, height: nil))
        return below ? 0 : max(mark.height * 0.45, size * 0.1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let inner = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: inner.width, height: inner.height + (below ? size * 0.12 : lift(subviews)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let inner = subviews[0].sizeThatFits(.unspecified)
        let lift = lift(subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + lift), proposal: .unspecified)
        let markProposal = ProposedViewSize(width: inner.width * 0.9, height: nil)
        if below {
            subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.maxY - size * 0.05), anchor: .center, proposal: markProposal)
        } else {
            subviews[1].place(at: CGPoint(x: bounds.midX + inner.width * 0.06, y: bounds.minY + (lift > size * 0.1 ? 0 : 0.02 * size)), anchor: .top, proposal: markProposal)
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guide == .mathAxis ? bounds.minY + lift(subviews) + subviews[0].dimensions(in: .unspecified)[.mathAxis] : nil
    }
}

/// Delimiters as tall as what they enclose.
private nonisolated struct MathFenceLayout: Layout {
    let size: CGFloat
    private var delimiterWidth: CGFloat { size * 0.38 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let inner = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: inner.width + 2 * delimiterWidth, height: inner.height + size * 0.1)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let delimiter = ProposedViewSize(width: delimiterWidth, height: bounds.height)
        subviews[0].place(at: bounds.origin, proposal: delimiter)
        subviews[1].place(at: CGPoint(x: bounds.minX + delimiterWidth, y: bounds.minY + size * 0.05), proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX - delimiterWidth, y: bounds.minY), proposal: delimiter)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guide == .mathAxis ? bounds.minY + size * 0.05 + subviews[1].dimensions(in: .unspecified)[.mathAxis] : nil
    }
}

// MARK: - Shapes

private nonisolated struct RadicalShape: Shape {
    let signWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.62))
            path.addLine(to: CGPoint(x: rect.minX + signWidth * 0.25, y: rect.minY + rect.height * 0.55))
            path.addLine(to: CGPoint(x: rect.minX + signWidth * 0.55, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + signWidth * 0.9, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}

/// `(`, `[`, `{`, `|`, `⟨` and their partners, stretched to the rectangle.
private nonisolated struct DelimiterShape: Shape {
    let delimiter: String

    func path(in rect: CGRect) -> Path {
        let mirrored = [")", "]", "}", "⟩", "⌋", "⌉"].contains(delimiter)
        let w = rect.width, h = rect.height
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
        switch delimiter {
        case "(", ")":
            path.move(to: point(0.75, 0))
            path.addQuadCurve(to: point(0.75, 1), control: point(0.05, 0.5))
        case "[", "]", "⌊", "⌋", "⌈", "⌉":
            let top = !["⌊", "⌋"].contains(delimiter), bottom = !["⌈", "⌉"].contains(delimiter)
            path.move(to: top ? point(0.75, 0) : point(0.3, 0))
            if top { path.addLine(to: point(0.3, 0)) }
            path.addLine(to: point(0.3, 1))
            if bottom { path.addLine(to: point(0.75, 1)) }
        case "{", "}":
            path.move(to: point(0.85, 0))
            path.addCurve(to: point(0.5, 0.15), control1: point(0.55, 0), control2: point(0.5, 0.05))
            path.addLine(to: point(0.5, 0.4))
            path.addCurve(to: point(0.15, 0.5), control1: point(0.5, 0.47), control2: point(0.3, 0.5))
            path.addCurve(to: point(0.5, 0.6), control1: point(0.3, 0.5), control2: point(0.5, 0.53))
            path.addLine(to: point(0.5, 0.85))
            path.addCurve(to: point(0.85, 1), control1: point(0.5, 0.95), control2: point(0.55, 1))
        case "|":
            path.move(to: point(0.5, 0))
            path.addLine(to: point(0.5, 1))
        case "‖":
            path.move(to: point(0.35, 0))
            path.addLine(to: point(0.35, 1))
            path.move(to: point(0.65, 0))
            path.addLine(to: point(0.65, 1))
        case "⟨", "⟩":
            path.move(to: point(0.75, 0))
            path.addLine(to: point(0.25, 0.5))
            path.addLine(to: point(0.75, 1))
        default:
            break
        }
        guard mirrored else { return path.offsetBy(dx: rect.minX, dy: rect.minY) }
        return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
