import SummaryKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A compile or reference error on a line of the open file.
struct PaperEditorIssue: Equatable {
    let line: Int
    let message: String
}

/// A line on screen: its 1-based number, the first fragment's rect, all its fragments', and the
/// text in each fragment, without indentation (text container coordinates). A line wrapped in from
/// above the visible area shows no number.
struct PaperVisibleLine {
    let number: Int
    let firstFragment: CGRect
    var bounds: CGRect
    var text: [CGRect]
    let showsNumber: Bool
}

/// Line geometry and the drawing shared by both platforms' editors (TextKit 1): the gutter's line
/// numbers and the errors, as a tinted line underlined with a red wave, its number in red over a
/// wave, and the message in a pill at its right edge.
enum PaperEditorDecorations {
    static let numberFont = EditorFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let pillFont = EditorFont.systemFont(ofSize: 11, weight: .medium)
    static let errorTint = EditorColor.systemRed.withAlphaComponent(0.1)
    static let pillColor = EditorColor.systemRed.withAlphaComponent(0.88)

    /// The gutter width for `lineCount` lines: at least three digits.
    static func gutterWidth(lineCount: Int) -> CGFloat {
        let digits = max(3, String(lineCount).count)
        let digit = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        return ceil(CGFloat(digits) * digit + 20)
    }

    static func visibleLines(in rect: CGRect, layoutManager: NSLayoutManager, container: NSTextContainer, lines: LaTeXLineIndex) -> [PaperVisibleLine] {
        var result: [PaperVisibleLine] = []
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let string = (layoutManager.textStorage?.string ?? "") as NSString
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let number = lines.line(at: characters.location)
            let text = textRect(of: characters, in: string, fragment: fragment, layoutManager: layoutManager, container: container)
            if let last = result.indices.last, result[last].number == number {
                result[last].bounds = result[last].bounds.union(fragment)
                if let text { result[last].text.append(text) }
            } else {
                let start = lines.starts[number - 1]
                result.append(PaperVisibleLine(
                    number: number, firstFragment: fragment, bounds: fragment, text: text.map { [$0] } ?? [],
                    showsNumber: characters.location == start
                ))
            }
        }
        // The empty last line after a final line break.
        let extra = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer != nil, extra.intersects(rect) || result.isEmpty {
            result.append(PaperVisibleLine(number: lines.lineCount, firstFragment: extra, bounds: extra, text: [], showsNumber: true))
        }
        return result
    }

    /// The rect of a fragment's text without leading and trailing whitespace; nil when it's blank.
    private static func textRect(
        of characters: NSRange, in string: NSString, fragment: CGRect, layoutManager: NSLayoutManager, container: NSTextContainer
    ) -> CGRect? {
        var start = characters.location
        var end = NSMaxRange(characters)
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isWhitespace(_ index: Int) -> Bool {
            UnicodeScalar(string.character(at: index)).map(whitespace.contains) ?? false
        }
        while start < end, isWhitespace(start) { start += 1 }
        while end > start, isWhitespace(end - 1) { end -= 1 }
        guard end > start else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: end - start), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        return CGRect(x: rect.minX, y: fragment.minY, width: rect.width, height: fragment.height)
    }

    /// Draws the numbers of `lines` right-aligned in a gutter `width` wide; `offset` moves container
    /// coordinates into the drawing's. Lines with errors are numbered in red over a wave.
    static func drawNumbers(_ lines: [PaperVisibleLine], width: CGFloat, offset: CGPoint, errors: Set<Int>, current: Int?) {
        for line in lines where line.showsNumber {
            let isError = errors.contains(line.number)
            let color: EditorColor = isError ? .systemRed : line.number == current ? .editorText : .editorSecondaryText
            let label = "\(line.number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: color]
            let size = label.size(withAttributes: attributes)
            let y = line.firstFragment.minY + offset.y + (line.firstFragment.height - size.height) / 2
            label.draw(at: CGPoint(x: width - size.width - 8, y: y), withAttributes: attributes)
            if isError {
                let dot = CGRect(x: 4, y: y + (size.height - 5) / 2, width: 5, height: 5)
                EditorColor.systemRed.setFill()
                pathWithOval(dot).fill()
                drawWave(from: width - size.width - 8, to: width - 8, y: y + size.height)
            }
        }
    }

    /// Underlines the text of the lines with errors with a red wave; a blank line gets a short one.
    static func drawErrorWaves(_ lines: [PaperVisibleLine], errors: Set<Int>, offset: CGPoint) {
        for line in lines where errors.contains(line.number) {
            let rects = line.text.isEmpty
                ? [CGRect(x: line.firstFragment.minX + 4, y: line.firstFragment.minY, width: 16, height: line.firstFragment.height)]
                : line.text
            for rect in rects {
                drawWave(from: rect.minX + offset.x, to: max(rect.maxX, rect.minX + 6) + offset.x, y: rect.maxY + offset.y - 2.5)
            }
        }
    }

    /// A red squiggle from `minX` to `maxX` around `y`.
    private static func drawWave(from minX: CGFloat, to maxX: CGFloat, y: CGFloat) {
        let amplitude: CGFloat = 1.5
        let step: CGFloat = 2
        let points = stride(from: minX, through: maxX, by: step).enumerated().map { index, x in
            CGPoint(x: x, y: y + (index.isMultiple(of: 2) ? -amplitude : amplitude))
        }
        guard points.count > 1 else { return }
        EditorColor.systemRed.setStroke()
        strokeLine(through: points, width: 1)
    }

    /// Tints the lines with errors across `width`.
    static func drawErrorTints(_ lines: [PaperVisibleLine], errors: Set<Int>, x: CGFloat, width: CGFloat, offset: CGPoint) {
        errorTint.setFill()
        for line in lines where errors.contains(line.number) {
            fill(CGRect(x: x, y: line.bounds.minY + offset.y, width: width, height: line.bounds.height))
        }
    }

    /// Draws each error line's first message in a pill ending at `maxX`; returns the pills' rects
    /// (drawing coordinates) by line, for hovering.
    @discardableResult
    static func drawPills(_ lines: [PaperVisibleLine], issues: [Int: [String]], maxX: CGFloat, maxWidth: CGFloat, offset: CGPoint) -> [Int: CGRect] {
        var rects: [Int: CGRect] = [:]
        let attributes: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: EditorColor.white]
        for line in lines {
            guard let messages = issues[line.number], let first = messages.first else { continue }
            let text = (messages.count > 1 ? "\(first) (+\(messages.count - 1))" : first) as NSString
            let textSize = text.size(withAttributes: attributes)
            let width = min(maxWidth, ceil(textSize.width) + 16)
            let height = min(line.firstFragment.height, ceil(textSize.height) + 2)
            let rect = CGRect(
                x: maxX - width,
                y: line.firstFragment.minY + offset.y + (line.firstFragment.height - height) / 2,
                width: width,
                height: height
            )
            pillColor.setFill()
            pathWithRoundedRect(rect, radius: height / 2).fill()
            let textRect = rect.insetBy(dx: 8, dy: (height - textSize.height) / 2)
            text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
            rects[line.number] = rect
        }
        return rects
    }

    #if os(iOS)
    private static func pathWithOval(_ rect: CGRect) -> UIBezierPath { UIBezierPath(ovalIn: rect) }
    private static func strokeLine(through points: [CGPoint], width: CGFloat) {
        let path = UIBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach(path.addLine(to:))
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.stroke()
    }
    private static func pathWithRoundedRect(_ rect: CGRect, radius: CGFloat) -> UIBezierPath { UIBezierPath(roundedRect: rect, cornerRadius: radius) }
    private static func fill(_ rect: CGRect) { UIRectFillUsingBlendMode(rect, .normal) }
    #else
    private static func pathWithOval(_ rect: CGRect) -> NSBezierPath { NSBezierPath(ovalIn: rect) }
    private static func strokeLine(through points: [CGPoint], width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach(path.line(to:))
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.stroke()
    }
    private static func pathWithRoundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
    private static func fill(_ rect: CGRect) { rect.fill(using: .sourceOver) }
    #endif
}

/// What's under the pointer: the word's description and the errors on its line, anchored to
/// the word (or the line). Coordinates are the text container's.
struct PaperHoverTarget: Equatable {
    let info: LaTeXHoverInfo?
    let errors: [String]
    let anchor: CGRect
}

extension PaperEditorDecorations {
    static func hoverTarget(
        at point: CGPoint,
        layoutManager: NSLayoutManager,
        container: NSTextContainer,
        text: String,
        lines: LaTeXLineIndex,
        issues: [Int: [String]],
        symbols: () -> LaTeXSymbols
    ) -> PaperHoverTarget? {
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y >= fragment.minY, point.y <= fragment.maxY else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let errors = issues[lines.line(at: index)] ?? []
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let info = glyphRect.contains(point) ? LaTeXInfo.info(in: text, at: index, symbols: symbols()) : nil
        guard info != nil || !errors.isEmpty else { return nil }
        let anchor = info.map {
            layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: $0.range, actualCharacterRange: nil), in: container)
        } ?? fragment
        return PaperHoverTarget(info: info, errors: errors, anchor: anchor)
    }
}

/// The card shown on hover: what the word is, and the errors on its line.
struct PaperHoverCard: View {
    let info: LaTeXHoverInfo?
    let errors: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(errors, id: \.self) { message in
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                .font(.callout)
            }
            if let info {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(info.detail)
                        .font(.callout)
                        .foregroundStyle(info.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    if let source = info.source {
                        Text(source)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
