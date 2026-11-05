import SummaryKit
import SwiftUI

/// Uses the canvas palette, including per-node color overrides.
struct GraphLegend: View {
    let nodes: [GraphNode]
    @State private var expanded = true

    private struct Key: Hashable {
        let types: [String]
        let color: String?
    }

    private var entries: [GraphNode] {
        var seen = Set<Key>()
        return nodes.filter { node in
            seen.insert(Key(types: node.types, color: node.color?.lowercased())).inserted
        }.sorted {
            let left = $0.types.joined(separator: ", ")
            let right = $1.types.joined(separator: ", ")
            return left == right ? ($0.color ?? "") < ($1.color ?? "") : left < right
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Label("Legend", systemImage: "circle.grid.2x2.fill")
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("graph-legend-toggle")
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { node in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(GraphPalette.color(for: node))
                                    .overlay { Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 1) }
                                    .frame(width: 12, height: 12)
                                    .padding(.top, 2)
                                Text(node.types.isEmpty ? String(localized: "Untyped") : node.types.joined(separator: " · "))
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(12)
        .frame(width: expanded ? 220 : 120)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .sensoryFeedback(.selection, trigger: expanded)
        .accessibilityIdentifier("graph-legend")
    }
}
