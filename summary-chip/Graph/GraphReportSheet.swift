import SwiftUI
import SummaryKit
import PDFKit
import CoreText
import UniformTypeIdentifiers

struct GraphReportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct GraphReportSheet: View {
    let graphID: String
    let document: GraphDocument
    let nodes: [GraphNode]
    let environment: AppEnvironment
    let printRequested: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var agent: ChatModel?
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var useAI = true
    @State private var language: SummaryLanguage = .auto
    @State private var file: GraphReportFile?
    @State private var exporting = false
    @State private var reportFilename = ""
    @State private var error: String?
    @State private var feedback = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title).font(.headline)
                            Text("\(nodes.count) nodes · PDF document")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.tint)
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    Picker("Content", selection: $useAI) {
                        Text("AI Report").tag(true)
                        Text("Graph Snapshot").tag(false)
                    }
                    .pickerStyle(.menu)
                    if useAI {
                        Picker("Report Language", selection: $language) {
                            ForEach(SummaryLanguage.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("graph-report-language")
                    }
                } header: {
                    Text("Report Options")
                } footer: {
                    Text(useAI
                         ? "Create a written analysis with sources, charts and a professional layout."
                         : "Export the selected graph data and its supporting content.")
                }

            }
            .formStyle(.grouped)
            .disabled(busy)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Graph Report")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { task?.cancel(); agent?.stop(); dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Create PDF", systemImage: "doc.badge.plus") {
                        if useAI { writeReport() } else { generate(analysis: nil) }
                    }
                    .disabled(busy)
                    .keyboardShortcut(.defaultAction)
                    Button("Save PDF", systemImage: "arrow.down.document") { exporting = true; feedback += 1 }.disabled(file == nil || busy)
                    #if !os(visionOS)
                    Button("Print", systemImage: "printer") { printPDF() }.disabled(file == nil || busy)
                    #endif
                }
            }
            .overlay {
                if busy {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Writing Report").font(.headline)
                        Text("Preparing your analysis and sources.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Cancel") { task?.cancel(); agent?.stop(); busy = false }
                    }.padding(24).frame(width: 300).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .fileExporter(isPresented: $exporting, document: file, contentType: .pdf, defaultFilename: reportFilename) { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }
                else { feedback += 1 }
            }
            .statusAlert("Report Failed", message: error) { error = nil }
            .sensoryFeedback(.success, trigger: feedback)
            .sensoryFeedback(.selection, trigger: language)
            .sensoryFeedback(.selection, trigger: useAI)
            .sensoryFeedback(.selection, trigger: busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .summarySheetSize()
        .interactiveDismissDisabled(busy)
        .onDisappear { task?.cancel(); agent?.stop() }
    }

    private func writeReport() {
        busy = true

        // Report generation must neither load nor save the library chat transcript.
        let writer = ChatModel(client: environment.chatClient, store: ChatTranscriptStore(directory: nil), graph: GraphChat(id: graphID))
        agent = writer
        writer.send("Use the dedicated writeReport agent to write a PDF report for these node IDs: \(nodes.map { $0.id }.joined(separator: ", ")). Output language: \(language.title). Return the report text.")
        task = Task { @MainActor in
            while writer.isStreaming {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            busy = false
            guard let entry = writer.entries.last, entry.errorText == nil, !entry.text.isEmpty else {
                error = writer.entries.last?.errorText ?? "The agent returned no report. Please try again."
                return
            }
            generate(analysis: entry.text)
        }
    }

    private func generate(analysis: String?) {
        let name = nodes.map { $0.label }.joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = (name.isEmpty ? document.title : name)
            .components(separatedBy: CharacterSet(charactersIn: "/:").union(.controlCharacters))
            .joined(separator: "-")
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        reportFilename = safeName + " - " + dateFormatter.string(from: Date())
        file = GraphReportFile(data: GraphReportRenderer.render(document: document, nodes: nodes, analysis: analysis))
        feedback += 1
        if printRequested { printPDF() } else { exporting = true }
    }

    private func printPDF() {
        guard let file else { return }
        #if os(macOS)
        guard let pdf = PDFDocument(data: file.data), let operation = pdf.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        operation.run()
        #elseif os(iOS)
        let controller = UIPrintInteractionController.shared
        controller.printingItem = file.data
        controller.present(animated: true) { _, _, failure in
            if let failure { error = failure.localizedDescription }
        }
        #endif
    }
}

@MainActor
private enum GraphReportRenderer {
    static func render(document: GraphDocument, nodes: [GraphNode], analysis: String?) -> Data {
        let body = reportBody(document: document, nodes: nodes, analysis: analysis)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        renderText(body, company: nodes.count == 1 ? nodes[0].label : document.title, in: context)
        context.closePDF()
        return data as Data
    }

    private static func reportBody(document: GraphDocument, nodes: [GraphNode], analysis: String?) -> NSAttributedString {
        let body = NSMutableAttributedString(string: "")
        func append(_ text: String, size: CGFloat = 11, bold: Bool = false, spacing: CGFloat = 9) {
            let base = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let font = bold ? CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base : base
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = spacing
            body.append(NSAttributedString(string: text + "\n", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                .paragraphStyle: paragraph,
                NSAttributedString.Key("reportHeading"): bold,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.08, green: 0.36, blue: 0.20, alpha: 1)
            ]))
        }
        let title = nodes.count == 1 ? nodes[0].label : document.title
        append(title + " - Research", size: 24, bold: true, spacing: 14)
        append("As of: " + Date().formatted() + " | Data: Graph snapshot", size: 9, spacing: 20)
        if let analysis {
            var columns = 1
            var figureKind: String?
            var figureJSON = ""
            for line in analysis.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "<!-- columns:1 -->" { columns = 1; continue }
                if trimmed == "<!-- columns:2 -->" { columns = 2; continue }
                if let kind = figureKind {
                    if trimmed == "```" {
                        if let data = figureJSON.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let items = object["items"] as? [[String: Any]], !items.isEmpty {
                            append(object["title"] as? String ?? kind.capitalized, size: 14, bold: true)
                            for item in items {
                                let start = body.length
                                let label = item["label"] as? String ?? ""
                                let detail = item["detail"] as? String ?? ""
                                let value = item["value"] as? Double
                                append(label + (value.map { ": " + String($0) } ?? "") + (detail.isEmpty ? "" : " — " + detail), spacing: 26)
                                let range = NSRange(location: start, length: body.length - start)
                                body.addAttribute(NSAttributedString.Key("reportFigure"), value: kind, range: range)
                                if let value, value.isFinite {
                                    let scale = items.compactMap { $0["value"] as? Double }.filter(\.isFinite).map { abs($0) }.max() ?? 1
                                    body.addAttribute(NSAttributedString.Key("reportValue"), value: value / max(scale, 0.000001), range: range)
                                }
                            }
                        } else { append(figureJSON) }
                        figureKind = nil
                        figureJSON = ""
                    } else { figureJSON += line + "\n" }
                    continue
                }
                if ["```chart", "```timeline", "```graph"].contains(trimmed) {
                    figureKind = String(trimmed.dropFirst(3)); continue
                }
                guard !trimmed.isEmpty else { continue }
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let text = level > 0 ? String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces) : trimmed
                let start = body.length
                append(text.replacingOccurrences(of: "**", with: ""), size: level > 0 ? (level < 3 ? 16 : 12) : 11, bold: level > 0)
                body.addAttribute(NSAttributedString.Key("reportColumns"), value: columns, range: NSRange(location: start, length: body.length - start))
            }
            if !figureJSON.isEmpty { append(figureJSON) }
        } else {
            append("Executive Summary", size: 16, bold: true)
            append("Research snapshot covering " + nodes.map { $0.label }.joined(separator: ", ") + ".")
            append("Company Overview", size: 16, bold: true)
            for node in nodes {
                append(node.label, size: 13, bold: true)
                if !node.types.isEmpty { append(node.types.joined(separator: ", ")) }
                for key in node.properties.keys.sorted() {
                    let data = (try? JSONEncoder().encode(node.properties[key])) ?? Data()
                    append(key + ": " + (String(data: data, encoding: .utf8) ?? ""))
                }
                for edge in document.edges where edge.source == node.id || edge.target == node.id {
                    let source = document.nodes.first { $0.id == edge.source }?.label ?? edge.source
                    let target = document.nodes.first { $0.id == edge.target }?.label ?? edge.target
                    append(source + (edge.directed ? " → " : " ↔ ") + target + " • " + edge.label)
                }
            }
            append("Appendix and Sources", size: 16, bold: true)
            append("Source: supplied graph snapshot. No independent financial verification or valuation was performed. Not rated.")
            for url in Set(nodes.flatMap { $0.images.map { $0.url.absoluteString } }).sorted() { append(url, size: 9) }
            append("This report is analysis, not investment advice. Figures are as of the timestamps shown and may have moved.", size: 9)
        }
        // The agent report already includes its own appendix and sources.
        // UI-derived content belongs only to the direct graph snapshot export.
        if analysis == nil {
            appendViewContent(document: document, nodes: nodes, append: append)
        }
        return body
    }

    private static func renderText(_ body: NSAttributedString, company: String, in context: CGContext) {
        GraphReportLayout.draw(body, company: company, in: context)
    }

    private static func appendViewContent(
        document: GraphDocument, nodes: [GraphNode],
        append: (String, CGFloat, Bool, CGFloat) -> Void
    ) {
        let selectedIDs = Set(nodes.map(\.id))
        let views: [(String, TripViewSpec)] = nodes.compactMap { node in
            node.view.map { (node.label, $0) }
        } + document.edges.filter { selectedIDs.contains($0.source) || selectedIDs.contains($0.target) }.compactMap { edge in
            edge.view.map { (edge.label, $0) }
        }
        for (label, spec) in views {
            append(label, 16, true, 14)
            var visited = Set<String>()
            func visit(_ id: String) {
                guard visited.insert(id).inserted, let element = spec.elements[id] else { return }
                let data = (try? JSONEncoder().encode(element.props)) ?? Data()
                let props = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                for line in reportLines(type: element.type, props: props) {
                    let heading = ["Heading", "Card", "Disclosure"].contains(element.type)
                    append(line, heading ? 13 : 11, heading, heading ? 12 : 8)
                }
                for child in element.children { visit(child) }
            }
            visit(spec.root)
        }
    }

    private static func reportValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "—" }
        if let cell = value as? [String: Any] {
            return [reportValue(cell["value"]), cell["detail"] as? String].compactMap { $0 }.joined(separator: " — ")
        }
        return String(describing: value)
    }

    private static func reportLines(type: String, props: [String: Any]) -> [String] {
        var lines = ["title", "subtitle", "caption", "text"].compactMap { props[$0] as? String }
        if type == "Table" {
            let columns = props["columns"] as? [[String: Any]] ?? []
            for row in props["rows"] as? [[String: Any]] ?? [] {
                let cells = row["cells"] as? [String: Any] ?? [:]
                lines.append(columns.map { column in
                    let key = column["key"] as? String ?? ""
                    return (column["label"] as? String ?? key) + ": " + reportValue(cells[key])
                }.joined(separator: "   •   "))
            }
        } else if let items = props["items"] as? [Any] {
            for (index, item) in items.enumerated() {
                if let item = item as? [String: Any] {
                    lines.append(reportItem(item))
                } else {
                    let prefix = props["ordered"] as? Bool == true ? "\(index + 1). " : "• "
                    lines.append(prefix + reportValue(item))
                }
            }
        }
        if type == "Stat" { lines.append(reportItem(props)) }
        for key in ["url", "credit", "placeId"] {
            if let text = props[key] as? String { lines.append(text) }
        }
        for image in props["images"] as? [[String: Any]] ?? [] {
            lines.append(["caption", "url", "credit"].compactMap { image[$0] as? String }.joined(separator: " — "))
        }
        return lines
    }

    private static func reportItem(_ props: [String: Any]) -> String {
        var value = reportValue(props["value"])
        if let number = props["value"] as? NSNumber {
            let formatter = NumberFormatter()
            switch props["format"] as? String {
            case "money":
                formatter.numberStyle = .currency
                formatter.currencyCode = props["currency"] as? String ?? "USD"
            case "percent": formatter.numberStyle = .percent
            default: formatter.numberStyle = .decimal
            }
            value = formatter.string(from: number) ?? value
        }
        return [(props["label"] as? String ?? "") + ": " + value, props["detail"] as? String]
            .compactMap { $0 }.joined(separator: " — ")
    }
}
