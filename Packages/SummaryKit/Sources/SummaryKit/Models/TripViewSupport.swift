import Foundation

// Reading a custom view's props, independent of SwiftUI: typed accessors over the raw JSON, how a
// value is formatted, and table totals. The renderer is `summary-chip/Trip/TripCustomView.swift`.

public extension TripViewElement {
    /// The catalog's container components; only these draw `children`.
    static let containerTypes: Set<String> = ["Stack", "Grid", "Card", "Disclosure"]

    func string(_ key: String) -> String? {
        switch props[key] {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value): value.formatted()
        default: nil
        }
    }

    func number(_ key: String) -> Double? {
        if case .number(let value) = props[key] { return value }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let value) = props[key] { return value }
        return nil
    }

    func strings(_ key: String) -> [String] {
        guard case .array(let items) = props[key] else { return [] }
        return items.compactMap(\.stringValue)
    }

    func objects(_ key: String) -> [[String: JSONValue]] {
        guard case .array(let items) = props[key] else { return [] }
        return items.compactMap { if case .object(let object) = $0 { object } else { nil } }
    }
}

public extension JSONValue {
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

/// How a view displays a value: text as is, numbers by `format` (`number`, `money`, `percent`).
public enum TripViewFormat {
    public static func text(_ value: JSONValue?, format: String?, currency: String?, defaultCurrency: String) -> String {
        switch value {
        case .string(let text): return text
        case .bool(let flag): return flag ? String(localized: "Yes", bundle: .module) : String(localized: "No", bundle: .module)
        case .number(let number):
            switch format {
            case "money": return TripMoney(amount: number, currency: currency ?? defaultCurrency).formatted
            case "percent": return (number / 100).formatted(.percent.precision(.fractionLength(0...1)))
            default: return number.formatted()
            }
        default: return "—"
        }
    }
}

/// A `Table` element's columns and rows, with the totals of columns marked `total`.
public struct TripViewTable: Sendable, Hashable {
    public struct Column: Sendable, Hashable, Identifiable {
        public var key: String
        public var label: String
        /// `leading`, `center` or `trailing`.
        public var align: String?
        public var format: String?
        public var currency: String?
        public var total: Bool
        public var id: String { key }
    }

    /// A cell: its value, an optional line of detail under it, and its tone.
    public struct Cell: Sendable, Hashable {
        public var value: JSONValue?
        public var detail: String?
        public var tone: String?
    }

    public struct Row: Sendable, Hashable {
        public var cells: [String: Cell]
        /// `default`, `muted`, `emphasis` or `total`.
        public var style: String?
    }

    public var caption: String?
    public var columns: [Column]
    public var rows: [Row]
    public var totalLabel: String?

    public init(_ element: TripViewElement) {
        caption = element.string("caption")
        totalLabel = element.string("totalLabel")
        columns = element.objects("columns").compactMap { column in
            guard let key = column["key"]?.stringValue else { return nil }
            return Column(
                key: key,
                label: column["label"]?.stringValue ?? key,
                align: column["align"]?.stringValue,
                format: column["format"]?.stringValue,
                currency: column["currency"]?.stringValue,
                total: column["total"] == .bool(true)
            )
        }
        rows = element.objects("rows").map { row in
            var cells: [String: Cell] = [:]
            if case .object(let raw) = row["cells"] {
                for (key, value) in raw {
                    if case .object(let object) = value {
                        cells[key] = Cell(value: object["value"], detail: object["detail"]?.stringValue, tone: object["tone"]?.stringValue)
                    } else {
                        cells[key] = Cell(value: value)
                    }
                }
            }
            return Row(cells: cells, style: row["style"]?.stringValue)
        }
    }

    /// Whether any column asks for a total row.
    public var hasTotals: Bool { columns.contains(where: \.total) }

    /// The sum of a column's numeric cells, skipping rows already styled as totals; nil when the
    /// column has no total.
    public func total(of column: Column) -> Double? {
        guard column.total else { return nil }
        return rows.filter { $0.style != "total" }.reduce(0) { sum, row in sum + (row.cells[column.key]?.value?.numberValue ?? 0) }
    }
}
