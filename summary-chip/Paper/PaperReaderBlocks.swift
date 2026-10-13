import SummaryKit
import SwiftUI

/// One block of the reader: a heading, paragraph, formula, figure, table, list…
struct PaperBlockView: View {
    let block: PaperBlock
    let context: PaperReaderContext

    private var size: CGFloat { context.fontSize }

    var body: some View {
        switch block.kind {
        case .title(let title):
            titleView(title)
        case .heading(let heading):
            headingView(heading)
        case .paragraph(let spans, let alignment):
            PaperParagraphView(spans: spans, alignment: alignment, context: context)
        case .equation(let equation):
            PaperEquationView(equation: equation, size: size)
        case .figure(let figure):
            PaperFigureView(figure: figure, context: context)
        case .table(let table):
            PaperTableView(table: table, context: context)
        case .list(let list):
            PaperListView(list: list, context: context)
        case .quote(let blocks):
            PaperBlocksView(blocks: blocks, context: context)
                .padding(.leading, size)
                .overlay(alignment: .leading) { Capsule().fill(.quaternary).frame(width: 3) }
        case .abstract(let blocks):
            VStack(alignment: .leading, spacing: size * 0.6) {
                Text("Abstract").font(context.font(0.95, style: [.bold, .smallCaps])).frame(maxWidth: .infinity)
                PaperBlocksView(blocks: blocks, context: context)
            }
            .padding(.horizontal, size * 1.2)
        case .theorem(let theorem):
            theoremView(theorem)
        case .code(let code, _):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: size * 0.82, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(size * 0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .contents(let headings):
            contentsView(headings)
        case .bibliography:
            bibliographyView
        }
    }

    // MARK: Text blocks

    private func titleView(_ title: PaperTitle) -> some View {
        VStack(spacing: size * 0.6) {
            Text(context.text(title.title, scale: 1.65, style: .bold))
                .multilineTextAlignment(.center)
            if !title.authors.isEmpty {
                Text(context.text(Array(title.authors.map { $0 + [PaperSpan.text("\u{2003}")] }.joined().dropLast()), scale: 1.05))
                    .multilineTextAlignment(.center)
            }
            if let date = title.date {
                Text(context.text(date, scale: 0.95)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, size * 0.8)
    }

    private func headingView(_ heading: PaperHeading) -> some View {
        let scale: CGFloat = [1.4, 1.22, 1.08, 1][min(max(heading.level, 1), 4) - 1]
        let prefix: [PaperSpan] = heading.number.map { [PaperSpan.text($0 + "\u{2003}")] } ?? []
        return Text(context.text(prefix + heading.title, scale: scale, style: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, size * (heading.level <= 2 ? 0.8 : 0.3))
            .accessibilityAddTraits(.isHeader)
    }

    private func theoremView(_ theorem: PaperTheorem) -> some View {
        let italic = ["Theorem", "Lemma", "Proposition", "Corollary", "Conjecture", "Claim"].contains(theorem.name)
        var header = theorem.name + (theorem.number.map { " \($0)" } ?? "")
        if let note = theorem.note { header += " (\(note.plainText))" }
        return VStack(alignment: .leading, spacing: size * 0.5) {
            Text(header + ".").font(context.font(1, style: theorem.isProof ? .italic : .bold))
            PaperBlocksView(blocks: theorem.blocks, context: context.with(italic ? .italic : []))
            if theorem.isProof {
                Image(systemName: "square").font(.system(size: size * 0.7)).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(theorem.isProof ? 0 : size * 0.8)
        .background {
            if !theorem.isProof {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.07))
            }
        }
    }

    private func contentsView(_ headings: [PaperHeading]) -> some View {
        VStack(alignment: .leading, spacing: size * 0.4) {
            Text("Contents").font(context.font(1.22, style: .bold))
            ForEach(headings, id: \.block) { heading in
                Link(destination: PaperReaderLink.block(heading.block).url ?? URL(fileURLWithPath: "/")) {
                    Text(context.text([PaperSpan.text((heading.number ?? "") + "\u{2003}")] + heading.title, scale: heading.level == 1 ? 1 : 0.95, style: heading.level == 1 ? .bold : []))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(heading.level - 1) * size)
            }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var bibliographyView: some View {
        if !context.document.bibliography.isEmpty {
            VStack(alignment: .leading, spacing: size * 0.6) {
                Text("References").font(context.font(1.4, style: .bold)).padding(.top, size * 0.8)
                ForEach(context.document.bibliography) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: size * 0.6) {
                        Text("[\(entry.number)]").font(context.font(0.9)).foregroundStyle(.secondary).monospacedDigit()
                        Text(context.text(entry.text, scale: 0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id("bib-\(entry.key)")
                }
            }
        }
    }
}

/// Blocks inside a list item, quote or theorem.
struct PaperBlocksView: View {
    let blocks: [PaperBlock]
    let context: PaperReaderContext

    var body: some View {
        VStack(alignment: .leading, spacing: context.fontSize * 0.7) {
            ForEach(blocks) { block in PaperBlockView(block: block, context: context) }
        }
    }
}

private struct PaperListView: View {
    let list: PaperList
    let context: PaperReaderContext

    var body: some View {
        VStack(alignment: .leading, spacing: context.fontSize * 0.45) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                if list.style == .description {
                    VStack(alignment: .leading, spacing: 4) {
                        if let label = item.label { Text(context.text(label, style: .bold)) }
                        PaperBlocksView(blocks: item.blocks, context: context).padding(.leading, context.fontSize)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: context.fontSize * 0.5) {
                        Group {
                            if let label = item.label { Text(context.text(label)) } else { Text(list.marker(index)).font(context.font()) }
                        }
                        .monospacedDigit()
                        .frame(minWidth: context.fontSize * 1.3, alignment: .trailing)
                        PaperBlocksView(blocks: item.blocks, context: context)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.leading, list.depth == 0 ? context.fontSize * 0.2 : 0)
    }
}

// MARK: - Equations

/// A display formula centered, its number at the right; `align` rows line up at `&`. Formulas
/// wider than the page scroll sideways.
struct PaperEquationView: View {
    let equation: PaperEquation
    let size: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(spacers: true)
            ScrollView(.horizontal) { grid(spacers: false) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(equation.source))
    }

    private var columns: Int { equation.rows.map(\.cells.count).max() ?? 1 }

    private func grid(spacers: Bool) -> some View {
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: size * 0.55) {
            ForEach(Array(equation.rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .center) {
                    if spacers { Color.clear.frame(minWidth: size, maxWidth: .infinity, maxHeight: 0).gridCellUnsizedAxes(.vertical) }
                    ForEach(0..<columns, id: \.self) { column in
                        let cell = column < row.cells.count ? row.cells[column] : []
                        PaperMathView(nodes: cell, size: size)
                            .gridColumnAlignment(equation.isAligned ? (column % 2 == 0 ? .trailing : .leading) : .center)
                    }
                    if spacers { Color.clear.frame(minWidth: size, maxWidth: .infinity, maxHeight: 0).gridCellUnsizedAxes(.vertical) }
                    Text(row.number.map { "(\($0))" } ?? "")
                        .font(.system(size: size, design: .serif))
                        .fixedSize()
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, size * 0.2)
    }
}

// MARK: - Tables

private struct PaperTableView: View {
    let table: PaperTable
    let context: PaperReaderContext

    private var size: CGFloat { context.fontSize }

    var body: some View {
        VStack(spacing: size * 0.6) {
            if let figure = table.figure { PaperFigureView(figure: figure, context: context) }
            if let caption = table.caption { PaperCaption(name: table.name, number: table.number, caption: caption, context: context) }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: size * 1.1, verticalSpacing: size * 0.45) {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                Text(context.text(cell.content, scale: 0.92, style: index < table.headerRows ? .bold : []))
                                    .fixedSize()
                                    .gridCellColumns(cell.columns)
                                    .gridColumnAlignment(alignment(column))
                            }
                        }
                        if index + 1 == table.headerRows { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch column < table.alignments.count ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// `Figure 2: The model.` under a figure or over a table.
struct PaperCaption: View {
    let name: String
    let number: String?
    let caption: [PaperSpan]
    let context: PaperReaderContext

    var body: some View {
        let label: [PaperSpan] = number.map { [PaperSpan.text("\(name) \($0): ", style: .bold)] } ?? []
        Text(context.text(label + caption, scale: 0.9))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, context.fontSize)
    }
}
