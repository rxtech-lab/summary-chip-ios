import SummaryKit
import SwiftUI

/// Draws a custom view's JSON spec with native components, json-render style: each element's
/// `type` picks a component from the catalog in `server/lib/contracts/trip-view.ts`, containers
/// draw their children by id. Unknown types and broken references draw nothing.
struct TripViewRenderer: View {
    let spec: TripViewSpec
    /// For `money` values without their own currency.
    let currency: String

    var body: some View {
        TripViewNode(id: spec.root, spec: spec, currency: currency, depth: 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A view with its title: a card of its own in the diary's Planning section, or a lighter panel inside a day.
/// Equatable on its data so scrolling, which re-renders the panes for the map, skips rebuilding
/// the spec's tree; the edit action only routes to a sheet.
struct TripCustomViewCard: View, Equatable {
    let view: TripView
    let currency: String
    var embedded = false
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(view.title, systemImage: "rectangle.3.group")
                    .font(embedded ? .subheadline.weight(.semibold) : .headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                TripEditButton(title: String(localized: "Edit view"), action: onEdit)
            }
            TripViewRenderer(spec: view.spec, currency: currency)
        }
        .padding(embedded ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            embedded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.summaryCardBackground),
            in: RoundedRectangle(cornerRadius: embedded ? 14 : 22, style: .continuous)
        )
        .overlay {
            if !embedded {
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.06))
            }
        }
        .accessibilityIdentifier("trip-view-\(view.id)")
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.view == rhs.view && lhs.currency == rhs.currency && lhs.embedded == rhs.embedded
    }
}

/// One element and, for containers, its children. Children are type-erased: the view is recursive.
private struct TripViewNode: View {
    let id: String
    let spec: TripViewSpec
    let currency: String
    let depth: Int
    /// A grid cell: boxed elements stretch to the row's tallest cell.
    var fillsCell = false
    @Environment(\.tripPlaces) private var places

    /// Deeper trees are cut off rather than risking runaway layout.
    private static let maxDepth = 24

    var body: some View {
        if depth < Self.maxDepth, let element = spec.elements[id] {
            content(element)
        }
    }

    @ViewBuilder
    private func content(_ element: TripViewElement) -> some View {
        switch element.type {
        case "Stack":
            let spacing = Self.spacing(element.string("gap"))
            if element.string("direction") == "horizontal" {
                HStack(alignment: .top, spacing: spacing) { children(of: element) }
            } else {
                VStack(alignment: .leading, spacing: spacing) { children(of: element) }
            }
        case "Grid":
            grid(element, columns: min(4, max(1, Int(element.number("columns") ?? 2))))
        case "Card":
            ViewCard(element: element, fillsHeight: fillsCell) { children(of: element) }
        case "Disclosure":
            ViewDisclosure(element: element) { children(of: element) }
        case "Heading":
            Text(element.string("text") ?? "")
                .font(Self.headingFont(element.number("level")))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case "Text":
            Text(element.string("text") ?? "")
                .font(Self.textFont(size: element.string("size"), weight: element.string("weight")))
                .foregroundStyle(TripViewTone.color(element.string("tone")))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case "Badge":
            let tint = TripViewTone.tint(element.string("tone"))
            Text(element.string("text") ?? "")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: Capsule())
        case "Stat":
            ViewStat(element: element, currency: currency, fillsHeight: fillsCell)
        case "Callout":
            ViewCallout(element: element, fillsHeight: fillsCell)
        case "KeyValue":
            ViewKeyValue(element: element, currency: currency)
        case "List":
            ViewList(element: element)
        case "Table":
            ViewTable(table: TripViewTable(element), currency: currency)
        case "BarChart":
            ViewBarChart(element: element, currency: currency)
        case "Divider":
            Divider()
        case "Link":
            link(element)
        case "Image":
            image(element)
        case "Gallery":
            gallery(element)
        case "Place":
            if let placeID = element.string("placeId"), let place = places.first(where: { $0.id == placeID }) {
                TripPlacePreviewCard(place: place)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func gallery(_ element: TripViewElement) -> some View {
        let photos = element.objects("images").compactMap { image -> TripPhoto? in
            guard let url = image["url"]?.stringValue else { return nil }
            return TripPhoto(url: url, caption: image["caption"]?.stringValue, credit: image["credit"]?.stringValue)
        }
        if !photos.isEmpty {
            TripPhotoCarousel(photos: photos, aspectRatio: 1)
                .frame(maxHeight: 260)
        }
    }

    @ViewBuilder
    private func link(_ element: TripViewElement) -> some View {
        if let url = element.string("url").flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
            Link(destination: url) {
                Label(element.string("title") ?? url.absoluteString, systemImage: "link")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private func image(_ element: TripViewElement) -> some View {
        if let url = element.string("url") {
            TripPhotoView(
                photo: TripPhoto(url: url, caption: element.string("caption"), credit: element.string("credit")),
                aspectRatio: Self.aspectRatio(element.string("aspect"))
            )
        }
    }

    private static func aspectRatio(_ aspect: String?) -> CGFloat {
        switch aspect {
        case "square": 1
        case "portrait": 3.0 / 4.0
        default: 16.0 / 9.0
        }
    }

    /// Rows of equal-height cells: each row is as tall as its tallest cell.
    private func grid(_ element: TripViewElement, columns count: Int) -> some View {
        let rows = stride(from: 0, to: element.children.count, by: count).map {
            Array(element.children[$0..<min($0 + count, element.children.count)])
        }
        return Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index], id: \.self) { child in
                        AnyView(TripViewNode(id: child, spec: spec, currency: currency, depth: depth + 1, fillsCell: true))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    // Keeps a short last row's cells at column width.
                    ForEach(rows[index].count..<count, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }

    private func children(of element: TripViewElement) -> some View {
        ForEach(element.children, id: \.self) { child in
            AnyView(TripViewNode(id: child, spec: spec, currency: currency, depth: depth + 1))
        }
    }

    private static func spacing(_ gap: String?) -> CGFloat {
        switch gap {
        case "none": 0
        case "small": 6
        case "large": 18
        default: 12
        }
    }

    private static func headingFont(_ level: Double?) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 3: .headline
        default: .title3.weight(.semibold)
        }
    }

    private static func textFont(size: String?, weight: String?) -> Font {
        let font: Font = switch size {
        case "small": .footnote
        case "large": .title3
        default: .body
        }
        return switch weight {
        case "semibold": font.weight(.semibold)
        case "bold": font.weight(.bold)
        default: font
        }
    }
}

/// The catalog's tones as colors.
enum TripViewTone {
    /// Text color: tones other than default and muted are tinted.
    static func color(_ tone: String?) -> Color {
        switch tone {
        case "muted": .secondary
        case nil, "default": .primary
        default: tint(tone)
        }
    }

    /// Fill and accent color.
    static func tint(_ tone: String?) -> Color {
        switch tone {
        case "accent": .accentColor
        case "positive", "success": .green
        case "negative": .red
        case "warning": .orange
        case "info": .blue
        case "tip": .yellow
        case "muted": .secondary
        default: .secondary
        }
    }
}

private struct ViewCard<Content: View>: View {
    let element: TripViewElement
    var fillsHeight = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let tone = element.string("tone")
        VStack(alignment: .leading, spacing: 10) {
            if element.string("title") != nil || element.string("subtitle") != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = element.string("title") {
                        Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    }
                    if let subtitle = element.string("subtitle") {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            tone == nil || tone == "default" ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(TripViewTone.tint(tone).opacity(0.1)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

private struct ViewDisclosure<Content: View>: View {
    let element: TripViewElement
    @ViewBuilder let content: () -> Content
    @State private var isExpanded: Bool

    init(element: TripViewElement, @ViewBuilder content: @escaping () -> Content) {
        self.element = element
        self.content = content
        _isExpanded = State(initialValue: element.bool("expanded") ?? false)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(element.string("title") ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .sensoryFeedback(.selection, trigger: isExpanded)
    }
}

private struct ViewStat: View {
    let element: TripViewElement
    let currency: String
    var fillsHeight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(element.string("label") ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(TripViewFormat.text(element.props["value"], format: element.string("format"), currency: element.string("currency"), defaultCurrency: currency))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(TripViewTone.color(element.string("tone")))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let detail = element.string("detail") {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ViewCallout: View {
    let element: TripViewElement
    var fillsHeight = false

    var body: some View {
        let tone = element.string("tone") ?? "info"
        let tint = TripViewTone.tint(tone)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(tone))
                .foregroundStyle(tint)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                if let title = element.string("title") {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text(element.string("text") ?? "")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private static func symbol(_ tone: String) -> String {
        switch tone {
        case "tip": "lightbulb"
        case "warning": "exclamationmark.triangle"
        case "success": "checkmark.seal"
        default: "info.circle"
        }
    }
}

private struct ViewKeyValue: View {
    let element: TripViewElement
    let currency: String

    var body: some View {
        let items = element.objects("items")
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(alignment: .firstTextBaseline) {
                    Text(item["label"]?.stringValue ?? "")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(TripViewFormat.text(item["value"], format: item["format"]?.stringValue, currency: item["currency"]?.stringValue, defaultCurrency: currency))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(TripViewTone.color(item["tone"]?.stringValue))
                }
                .font(.subheadline)
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                if index < items.count - 1 { Divider() }
            }
        }
    }
}

private struct ViewList: View {
    let element: TripViewElement

    var body: some View {
        let ordered = element.bool("ordered") ?? false
        let items = element.strings("items")
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(items[index])
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
            }
        }
    }
}

private struct ViewTable: View {
    let table: TripViewTable
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption = table.caption {
                Text(caption).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            // A grid when it fits the width; on narrow screens each row becomes a block of its own.
            ViewThatFits(in: .horizontal) {
                grid
                stacked
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(table.columns) { column in
                    Text(column.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(horizontal(column))
                }
            }
            Divider()
            ForEach(table.rows.indices, id: \.self) { index in
                let row = table.rows[index]
                if row.style == "total" { Divider() }
                GridRow {
                    ForEach(table.columns) { column in
                        cell(row.cells[column.key], column: column, style: row.style)
                    }
                }
            }
            if table.hasTotals {
                Divider()
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                        if let total = table.total(of: column) {
                            Text(TripViewFormat.text(.number(total), format: column.format, currency: column.currency, defaultCurrency: currency))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                        } else if index == 0 {
                            Text(table.totalLabel ?? String(localized: "Total"))
                                .font(.subheadline.weight(.bold))
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    /// The leading text columns title each block; the other columns are its label / value lines.
    private var titleColumns: [TripViewTable.Column] {
        let leading = Array(table.columns.prefix { $0.format == nil || $0.format == "text" })
        return leading.isEmpty ? Array(table.columns.prefix(1)) : leading
    }

    private var stacked: some View {
        let titles = titleColumns
        let values = table.columns.filter { column in !titles.contains(column) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(table.rows.indices, id: \.self) { index in
                let row = table.rows[index]
                let bold = row.style == "emphasis" || row.style == "total"
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titles.map { TripViewFormat.text(row.cells[$0.key]?.value, format: $0.format, currency: $0.currency, defaultCurrency: currency) }.joined(separator: " · "))
                            .font(.subheadline.weight(bold ? .bold : .semibold))
                            .foregroundStyle(row.style == "muted" ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = titles.lazy.compactMap({ row.cells[$0.key]?.detail }).last {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    ForEach(values) { column in
                        let cell = row.cells[column.key]
                        HStack(alignment: .firstTextBaseline) {
                            Text(column.label).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if let detail = cell?.detail {
                                Text(detail).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(TripViewFormat.text(cell?.value, format: column.format, currency: column.currency, defaultCurrency: currency))
                                .fontWeight(bold ? .bold : .medium)
                                .monospacedDigit()
                                .foregroundStyle(TripViewTone.color(cell?.tone))
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                Divider()
            }
            if table.hasTotals {
                VStack(alignment: .leading, spacing: 6) {
                    Text(table.totalLabel ?? String(localized: "Total"))
                        .font(.subheadline.weight(.bold))
                    ForEach(table.columns.filter(\.total)) { column in
                        HStack(alignment: .firstTextBaseline) {
                            Text(column.label).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(TripViewFormat.text(table.total(of: column).map(JSONValue.number), format: column.format, currency: column.currency, defaultCurrency: currency))
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func cell(_ cell: TripViewTable.Cell?, column: TripViewTable.Column, style: String?) -> some View {
        let isNumeric = cell?.value?.numberValue != nil
        VStack(alignment: horizontal(column), spacing: 1) {
            Text(TripViewFormat.text(cell?.value, format: column.format, currency: column.currency, defaultCurrency: currency))
                .font(.subheadline.weight(style == "emphasis" || style == "total" ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(style == "muted" ? .secondary : TripViewTone.color(cell?.tone))
            if let detail = cell?.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        // Long text wraps in its column; numbers stay on one line.
        .frame(maxWidth: isNumeric ? nil : 220, alignment: Alignment(horizontal: horizontal(column), vertical: .top))
        .fixedSize(horizontal: isNumeric, vertical: true)
    }

    private func horizontal(_ column: TripViewTable.Column) -> HorizontalAlignment {
        switch column.align {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
    }
}

private struct ViewBarChart: View {
    let element: TripViewElement
    let currency: String

    var body: some View {
        let items = element.objects("items")
        let values = items.map { $0["value"]?.numberValue ?? 0 }
        let largest = max(values.map(abs).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 10) {
            if let title = element.string("title") {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let tone = item["tone"]?.stringValue
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item["label"]?.stringValue ?? "")
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Text(TripViewFormat.text(item["value"], format: element.string("format"), currency: element.string("currency"), defaultCurrency: currency))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 10)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(tone == nil || tone == "default" ? Color.accentColor : TripViewTone.tint(tone))
                                    .frame(width: max(10, proxy.size.width * abs(values[index]) / largest))
                            }
                        }
                    if let detail = item["detail"]?.stringValue {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
