import Charts
import SummaryKit
import SwiftUI

struct ViewBarChart: View {
    @State private var selectedIndex: Int?
    let element: TripViewElement
    let currency: String

    var body: some View {
        let items = element.objects("items")
        VStack(alignment: .leading, spacing: 10) {
            if let title = element.string("title") {
                Text(title).font(.subheadline.weight(.semibold))
            }
            Chart {
                ForEach(items.indices, id: \.self) { index in
                    BarMark(
                        x: .value("Value", items[index]["value"]?.numberValue ?? 0),
                        y: .value("Item", String(index))
                    )
                    .foregroundStyle(TripViewTone.tint(items[index]["tone"]?.stringValue))
                    .annotation(position: .trailing) {
                        if element.props["showLabels"] == .bool(true) || selectedIndex == index {
                            chartLabel(element, item: items[index], currency: currency)
                        }
                    }
                    .accessibilityLabel(items[index]["label"]?.stringValue ?? "")
                    .accessibilityValue(TripViewFormat.text(items[index]["value"], format: element.string("format"), currency: element.string("currency"), defaultCurrency: currency))
                }
            }
            .modifier(NativeChartSelection(element: element, selectedIndex: $selectedIndex))
            .sensoryFeedback(.selection, trigger: selectedIndex)
            .chartYAxis {
                AxisMarks { axis in
                    AxisValueLabel {
                        if let key = axis.as(String.self), let index = Int(key), items.indices.contains(index) {
                            Text(items[index]["label"]?.stringValue ?? "")
                        }
                    }
                }
            }
            .frame(height: max(180, CGFloat(items.count) * 36))
        }
    }
}


struct ViewSeriesChart: View {
    @State private var selectedIndex: Int?
    let element: TripViewElement
    let currency: String

    var body: some View {
        let items = element.objects("items")
        VStack(alignment: .leading, spacing: 10) {
            if let title = element.string("title") {
                Text(title).font(.subheadline.weight(.semibold))
            }
            Chart {
                ForEach(items.indices, id: \.self) { index in
                    let value = items[index]["value"]?.numberValue ?? 0
                    if element.type == "PieChart" {
                        SectorMark(angle: .value("Value", max(0, value)))
                            .foregroundStyle(by: .value("Item", items[index]["label"]?.stringValue ?? ""))
                            .annotation(position: .overlay) {
                                if element.props["showLabels"] == .bool(true) || selectedIndex == index {
                                    chartLabel(element, item: items[index], currency: currency)
                                }
                            }
                            .accessibilityLabel(items[index]["label"]?.stringValue ?? "")
                            .accessibilityValue(TripViewFormat.text(items[index]["value"], format: element.string("format"), currency: element.string("currency"), defaultCurrency: currency))
                    } else if element.type == "ScatterChart" {
                        PointMark(
                            x: .value(element.string("xLabel") ?? "X", items[index]["x"]?.numberValue ?? 0),
                            y: .value(element.string("yLabel") ?? "Y", items[index]["y"]?.numberValue ?? 0)
                        )
                        .annotation(position: .top) {
                            if element.props["showLabels"] == .bool(true) || selectedIndex == index {
                                chartLabel(element, item: items[index], currency: currency)
                            }
                        }
                        .accessibilityLabel(items[index]["label"]?.stringValue ?? "")
                        .accessibilityValue("X: \(items[index]["x"]?.numberValue ?? 0), Y: \(items[index]["y"]?.numberValue ?? 0)")
                    } else {
                    if element.type == "AreaChart" {
                        AreaMark(x: .value("Position", index), y: .value("Value", value))
                            .foregroundStyle(Color.accentColor.opacity(0.2))
                    }
                    LineMark(x: .value("Position", index), y: .value("Value", value))
                    PointMark(x: .value("Position", index), y: .value("Value", value))
                        .annotation(position: .top) {
                            if element.props["showLabels"] == .bool(true) || selectedIndex == index {
                                chartLabel(element, item: items[index], currency: currency)
                            }
                        }
                        .accessibilityLabel(items[index]["label"]?.stringValue ?? "")
                        .accessibilityValue(TripViewFormat.text(items[index]["value"], format: element.string("format"), currency: element.string("currency"), defaultCurrency: currency))
                    }
                }
            }
            .modifier(NativeChartSelection(element: element, selectedIndex: $selectedIndex))
            .sensoryFeedback(.selection, trigger: selectedIndex)
            .chartXAxis {
                if element.type == "ScatterChart" {
                    AxisMarks()
                } else if element.type != "PieChart" {
                AxisMarks(values: Array(items.indices)) { axis in
                    AxisValueLabel {
                        if let index = axis.as(Int.self), items.indices.contains(index) {
                            Text(items[index]["label"]?.stringValue ?? "")
                        }
                    }
                }
                }
            }
            .chartXAxisLabel(element.string("xLabel") ?? "")
            .chartYAxisLabel(element.string("yLabel") ?? "")
            .frame(height: 220)
        }
    }
}

private func chartLabel(_ element: TripViewElement, item: [String: JSONValue], currency: String) -> some View {
    VStack(spacing: 2) {
        Text(item["label"]?.stringValue ?? "").fontWeight(.semibold)
        if element.type == "ScatterChart" {
            Text("\(element.string("xLabel") ?? "X"): \(item["x"]?.numberValue ?? 0, format: .number), \(element.string("yLabel") ?? "Y"): \(item["y"]?.numberValue ?? 0, format: .number)")
        } else {
            Text(TripViewFormat.text(item["value"], format: element.string("format"), currency: element.string("currency"), defaultCurrency: currency))
        }
        if let detail = item["detail"]?.stringValue { Text(detail) }
    }
    .font(.caption)
    .padding(5)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    .allowsHitTesting(false)
}

/// Swift Charts supplies platform-native hover and touch selection gestures.
private struct NativeChartSelection: ViewModifier {
    let element: TripViewElement
    @Binding var selectedIndex: Int?
    @State private var selectedX: Double?
    @State private var selectedY: Double?
    @State private var selectedCategory: String?
    @State private var selectedAngle: Double?

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            switch element.type {
            case "PieChart":
                content.chartAngleSelection(value: $selectedAngle)
            case "BarChart":
                content.chartYSelection(value: $selectedCategory)
            case "ScatterChart":
                content.chartXSelection(value: $selectedX)
                    .chartYSelection(value: $selectedY)
            default:
                content.chartXSelection(value: $selectedX)
            }
        }
        .onChange(of: selectedX) { _, _ in updateSelection() }
        .onChange(of: selectedY) { _, _ in updateSelection() }
        .onChange(of: selectedCategory) { _, _ in updateSelection() }
        .onChange(of: selectedAngle) { _, _ in updateSelection() }
        .onChange(of: element) { _, _ in
            selectedX = nil
            selectedY = nil
            selectedCategory = nil
            selectedAngle = nil
            selectedIndex = nil
        }
    }

    private func updateSelection() {
        let items = element.objects("items")
        switch element.type {
        case "PieChart":
            guard let selectedAngle else { selectedIndex = nil; return }
            var cumulative = 0.0
            selectedIndex = items.indices.first { index in
                cumulative += max(0, items[index]["value"]?.numberValue ?? 0)
                return cumulative > selectedAngle
            }
        case "BarChart":
            selectedIndex = selectedCategory.flatMap(Int.init).flatMap { items.indices.contains($0) ? $0 : nil }
        case "ScatterChart":
            guard let selectedX, let selectedY else { selectedIndex = nil; return }
            // Normalize both axes so different units do not dominate nearest-point selection.
            let xs = items.map { $0["x"]?.numberValue ?? 0 }
            let ys = items.map { $0["y"]?.numberValue ?? 0 }
            let width = max((xs.max() ?? 0) - (xs.min() ?? 0), .leastNonzeroMagnitude)
            let height = max((ys.max() ?? 0) - (ys.min() ?? 0), .leastNonzeroMagnitude)
            func distance(_ index: Int) -> Double {
                hypot((xs[index] - selectedX) / width, (ys[index] - selectedY) / height)
            }
            selectedIndex = items.indices.min { distance($0) < distance($1) }
        default:
            guard let selectedX else { selectedIndex = nil; return }
            selectedIndex = items.indices.min { abs(Double($0) - selectedX) < abs(Double($1) - selectedX) }
        }
    }
}
