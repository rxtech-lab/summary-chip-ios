import Foundation

extension PaperReaderParser {
    // MARK: Floats

    private static let tabularEnvironments: Set<String> = ["tabular", "tabular*", "tabularx", "tabulary", "longtable", "xltabular", "tblr", "array"]
    private static let drawingEnvironments: Set<String> = ["tikzpicture", "pgfpicture", "circuitikz", "forest", "tikzcd"]

    /// A `figure` or `table`: its images, drawings and tables, caption and number.
    func float(_ raw: String, environment: String) -> [PaperBlock] {
        let isTable = environment.contains("table")
        let id = newID()
        let (images, drawings, drawingSources, caption, labels, tabulars) = floatContent(raw)
        guard !images.isEmpty || drawings > 0 || !tabulars.isEmpty else {
            return nested(raw, alignment: .center)
        }
        let name = isTable ? "Table" : "Figure"
        var number: String?
        if caption != nil, environment != "subfloat" {
            if isTable { tableCount += 1; number = floatNumber(tableCount) } else { figureCount += 1; number = floatNumber(figureCount) }
        }
        let target = PaperLabel(kind: isTable ? .table : .figure, number: number ?? "", name: name, block: id)
        labelTarget = target
        for key in labels where number != nil { document.labels[key] = target }
        let captionSpans = caption.map { Self.trimmed(parseInline($0)) }
        let figure = PaperFigure(images: images, drawings: drawings, caption: captionSpans, number: number, name: name, drawingSources: drawingSources)
        guard let first = tabulars.first else {
            return [PaperBlock(id: id, kind: .figure(figure))]
        }
        var table = table(first.body, environment: first.environment)
        table.caption = captionSpans
        table.number = number
        table.name = name
        table.figure = images.isEmpty && drawings == 0 ? nil : PaperFigure(images: images, drawings: drawings, caption: nil, number: nil, name: name, drawingSources: drawingSources)
        return [PaperBlock(id: id, kind: .table(table))] + tabulars.dropFirst().map {
            PaperBlock(id: newID(), kind: .table(self.table($0.body, environment: $0.environment)))
        }
    }

    private func floatContent(_ raw: String) -> (
        images: [PaperFigure.Image], drawings: Int, drawingSources: [String], caption: String?,
        labels: [String], tabulars: [(environment: String, body: String)]
    ) {
        var images: [PaperFigure.Image] = []
        var drawings = 0
        var drawingSources: [String] = []
        var caption: String?
        var labels: [String] = []
        var tabulars: [(environment: String, body: String)] = []
        var subfigureDepth = 0
        parsing(raw) {
            while !isAtEnd {
                guard chars[pos] == "\\" else { pos += 1; continue }
                pos += 1
                switch readLetters() {
                case "includegraphics":
                    images.append(includedImage())
                case "caption", "subcaption":
                    _ = readOptional()
                    let text = readGroup() ?? ""
                    if subfigureDepth > 0, !images.isEmpty {
                        images[images.count - 1].caption = Self.trimmed(parseInline(text))
                    } else {
                        caption = text
                    }
                case let command where command == "subfloat" || command == "subcaptionbox":
                    let subcaption = command == "subfloat" ? readOptional() : readGroup()
                    let before = images.count
                    let inner = float(readGroup() ?? "", environment: "subfloat")
                    for block in inner {
                        guard case .figure(let figure) = block.kind else { continue }
                        images += figure.images
                        drawings += figure.drawings
                        drawingSources += figure.drawingSources
                    }
                    if let subcaption, images.count > before { images[images.count - 1].caption = Self.trimmed(parseInline(subcaption)) }
                case "label":
                    if subfigureDepth == 0, let key = readGroup() { labels.append(key.trimmingCharacters(in: .whitespaces)) }
                case "begin":
                    let name = readGroup() ?? ""
                    if Self.tabularEnvironments.contains(name) {
                        tabulars.append((name, readEnvironment(name)))
                    } else if Self.drawingEnvironments.contains(name) {
                        drawingSources.append("\\begin{\(name)}" + readEnvironment(name) + "\\end{\(name)}")
                        drawings += 1
                    } else if name == "subfigure" || name == "subtable" {
                        _ = readOptional()
                        _ = readGroup()
                        subfigureDepth += 1
                    }
                case "end":
                    let name = readGroup() ?? ""
                    if name == "subfigure" || name == "subtable" { subfigureDepth = max(subfigureDepth - 1, 0) }
                default:
                    break
                }
            }
        }
        return (images, drawings, drawingSources, caption, labels, tabulars)
    }

    // MARK: Images

    func includedImage() -> PaperFigure.Image {
        _ = readStar()
        let options = readOptional() ?? ""
        let requested = (readGroup() ?? "").trimmingCharacters(in: .whitespaces)
        return PaperFigure.Image(path: imagePath(requested), requested: requested, width: Self.widthFraction(options), caption: nil)
    }

    /// The paper file `\includegraphics` means: under each `\graphicspath`, with or without its extension.
    func imagePath(_ name: String) -> String? {
        var name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        while name.hasPrefix("./") { name.removeFirst(2) }
        let images = source.files.filter(\.isImage)
        for prefix in graphicsPaths {
            var base = prefix + name
            while base.hasPrefix("./") { base.removeFirst(2) }
            for candidate in [base] + ["png", "jpg", "jpeg", "pdf", "PNG", "JPG", "JPEG", "PDF"].map({ base + "." + $0 }) {
                if let file = images.first(where: { $0.path == candidate }) { return file.path }
            }
        }
        return nil
    }

    /// `width=0.5\linewidth` → 0.5.
    static func widthFraction(_ options: String) -> Double? {
        let pattern = try! NSRegularExpression(pattern: #"width\s*=\s*([0-9.]*)\s*\\(?:linewidth|textwidth|columnwidth|hsize)"#)
        let string = options as NSString
        guard let match = pattern.firstMatch(in: options, range: NSRange(location: 0, length: string.length)) else { return nil }
        let value = string.substring(with: match.range(at: 1))
        return value.isEmpty ? 1 : Double(value).map { min(max($0, 0.1), 1) }
    }

    // MARK: Tables

    func tableBlocks(_ body: String, environment: String) -> [PaperBlock] {
        let id = newID()
        var table = table(body, environment: environment)
        if table.caption != nil {
            tableCount += 1
            table.number = floatNumber(tableCount)
        }
        return [PaperBlock(id: id, kind: .table(table))]
    }

    /// A `tabular`'s rows and cells, at its body: column specification first.
    func table(_ body: String, environment: String) -> PaperTable {
        let (alignments, content) = parsing(body) { () -> ([PaperAlignment], String) in
            if environment.hasPrefix("tabular*") || ["tabularx", "tabulary", "xltabular"].contains(environment) { _ = readGroup() }
            _ = readOptional()
            let alignments = Self.columnAlignments(readGroup() ?? "")
            return (alignments, String(chars[pos...]))
        }
        var text = content.replacingOccurrences(of: "\\tabularnewline", with: "\\\\")
        let caption = Self.extract("caption", from: &text).first
        _ = Self.extract("label", from: &text)
        var rows: [[PaperTable.Cell]] = []
        var headerRows = 0
        var hasTopRule = false
        for raw in Self.splitTopLevel(text, at: "\\\\") {
            var row = raw
            if let optional = row.range(of: #"^\s*\[[^\]]*\]"#, options: .regularExpression) { row.removeSubrange(optional) }
            let startsWithRule = row.range(of: #"^\s*\\(?:hline|toprule|midrule|cmidrule|cline|hhline|Xhline)"#, options: .regularExpression) != nil
            if startsWithRule {
                if rows.isEmpty { hasTopRule = true } else if headerRows == 0, hasTopRule, rows.count <= 3 { headerRows = rows.count }
            }
            row = row.replacingOccurrences(of: #"\\(?:hline|toprule|midrule|bottomrule|endhead|endfirsthead|endfoot|endlastfoot|addlinespace|hhline|Xhline)(?:\[[^\]]*\])?(?:\{[^}]*\})?"#, with: "", options: .regularExpression)
            row = row.replacingOccurrences(of: #"\\(?:cline|cmidrule)(?:\([^)]*\))?\{[^}]*\}"#, with: "", options: .regularExpression)
            row = row.replacingOccurrences(of: #"\\rowcolor(?:\[[^\]]*\])?\{[^}]*\}"#, with: "", options: .regularExpression)
            let cells = Self.splitTopLevel(row, at: "&").map(cell)
            if cells.count == 1, cells[0].content.isEmpty { continue }
            rows.append(cells)
        }
        return PaperTable(
            rows: rows, headerRows: headerRows, alignments: alignments,
            caption: caption.map { Self.trimmed(parseInline($0)) }, number: nil, name: "Table", figure: nil
        )
    }

    private func cell(_ raw: String) -> PaperTable.Cell {
        parsing(raw) {
            skipSpaces()
            if hasCommand("multicolumn") {
                pos += "\\multicolumn".count
                let columns = Int((readGroup() ?? "1").trimmingCharacters(in: .whitespaces)) ?? 1
                _ = readGroup()
                return PaperTable.Cell(content: Self.trimmed(parseInline(readGroup() ?? "")), columns: max(columns, 1))
            }
            if hasCommand("multirow") {
                pos += "\\multirow".count
                _ = readOptional()
                _ = readGroup()
                _ = readOptional()
                _ = readGroup()
                return PaperTable.Cell(content: Self.trimmed(parseInline(readGroup() ?? "")), columns: 1)
            }
            return PaperTable.Cell(content: Self.trimmed(parseInline(String(chars[pos...]))), columns: 1)
        }
    }

    /// `l|c|r p{3cm} *{2}{c}` → leading, center, trailing, leading, center, center.
    static func columnAlignments(_ spec: String) -> [PaperAlignment] {
        var result: [PaperAlignment] = []
        var chars = Array(spec)[...]
        func group() -> String {
            guard chars.first == "{" else { return "" }
            var depth = 0
            var text = ""
            while let c = chars.popFirst() {
                if c == "{" { depth += 1; if depth == 1 { continue } }
                if c == "}" { depth -= 1; if depth == 0 { break } }
                text.append(c)
            }
            return text
        }
        while let c = chars.popFirst() {
            switch c {
            case "l", "p", "m", "b", "X", "L", "J": result.append(.leading); if "pmb".contains(c) { _ = group() }
            case "c", "S", "C": result.append(.center)
            case "r", "R": result.append(.trailing)
            case "@", "!", ">", "<": _ = group()
            case "*":
                let count = Int(group().trimmingCharacters(in: .whitespaces)) ?? 1
                let repeated = columnAlignments(group())
                for _ in 0..<min(count, 50) { result += repeated }
            default: break
            }
        }
        return result
    }
}
