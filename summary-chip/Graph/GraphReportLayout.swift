import Foundation
import CoreText
import CoreGraphics

/// Flows selectable text through balanced column bands; figures remain full width.
enum GraphReportLayout {
    static func draw(_ body: NSAttributedString, company: String, in context: CGContext) {
        let columnKey = NSAttributedString.Key("reportColumns")
        // A4 points: generous outer margins and a separate footer area.
        let pageWidth: CGFloat = 595
        let pageHeight: CGFloat = 842
        let horizontalMargin: CGFloat = 64
        let topMargin: CGFloat = 72
        let contentBottom: CGFloat = 80
        let columnGap: CGFloat = 28
        let contentWidth = pageWidth - 2 * horizontalMargin
        var offset = 0
        var top = pageHeight - topMargin
        var page = 0
        let ink = CGColor(red: 0.08, green: 0.36, blue: 0.20, alpha: 1)
        func beginPage() {
            page += 1
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.setStrokeColor(ink)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: horizontalMargin, y: 54))
            context.addLine(to: CGPoint(x: pageWidth - horizontalMargin, y: 54))
            context.strokePath()
            let footer = NSAttributedString(string: company + "  •  " + String(page), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 8, nil)
            ])
            let setter = CTFramesetterCreateWithAttributedString(footer)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: horizontalMargin, y: 26, width: contentWidth, height: 20), transform: nil), nil), context)
            top = pageHeight - topMargin
        }
        beginPage()
        while offset < body.length {
            let columns = body.attribute(columnKey, at: offset, effectiveRange: nil) as? Int ?? 1
            var end = offset
            while end < body.length {
                if (body.attribute(columnKey, at: end, effectiveRange: nil) as? Int ?? 1) != columns { break }
                end = NSMaxRange((body.string as NSString).paragraphRange(for: NSRange(location: end, length: 0)))
            }
            let section = body.attributedSubstring(from: NSRange(location: offset, length: end - offset))
            let setter = CTFramesetterCreateWithAttributedString(section)
            let width = (contentWidth - CGFloat(columns - 1) * columnGap) / CGFloat(columns)
            let estimated = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
            let available = top - contentBottom
            if available < 70 { context.endPDFPage(); beginPage(); continue }
            let height = min(available, ceil(estimated / CGFloat(columns)) + 24)
            var consumed = 0
            for column in 0..<columns where consumed < section.length {
                let rect = CGRect(x: horizontalMargin + CGFloat(column) * (width + columnGap), y: top - height, width: width, height: height)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: consumed, length: 0), CGPath(rect: rect, transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { continue }
                CTFrameDraw(frame, context)
                drawFigures(section, frame: frame, rect: rect, context: context, ink: ink)
                consumed += visible.length
            }
            if consumed == 0 { context.endPDFPage(); beginPage(); continue }
            offset += consumed
            top -= height + 14
            if consumed < section.length { context.endPDFPage(); beginPage() }
        }
        context.endPDFPage()
    }

    private static func drawFigures(_ text: NSAttributedString, frame: CTFrame, rect: CGRect, context: CGContext, ink: CGColor) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        for (index, line) in lines.enumerated() {
            let location = CTLineGetStringRange(line).location
            guard location < text.length,
                  let kind = text.attribute(NSAttributedString.Key("reportFigure"), at: location, effectiveRange: nil) as? String,
                  NSMaxRange((text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))) <= location + CTLineGetStringRange(line).length else { continue }
            let y = rect.minY + origins[index].y - 17
            context.setFillColor(ink)
            context.setStrokeColor(ink)
            if kind == "chart", let value = text.attribute(NSAttributedString.Key("reportValue"), at: location, effectiveRange: nil) as? Double {
                let middle = rect.midX
                let length = CGFloat(abs(value)) * rect.width / 2
                context.fill(CGRect(x: value < 0 ? middle - length : middle, y: y, width: max(1, length), height: 5))
                context.fill(CGRect(x: middle, y: y - 2, width: 0.5, height: 9))
            } else {
                context.fillEllipse(in: CGRect(x: rect.minX, y: y, width: 5, height: 5))
                context.setLineWidth(0.7)
                context.move(to: CGPoint(x: rect.minX + 8, y: y + 2.5))
                context.addLine(to: CGPoint(x: rect.minX + (kind == "timeline" ? 32 : 70), y: y + 2.5))
                context.strokePath()
            }
        }
    }
}
