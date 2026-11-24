import SummaryKit
import SwiftUI

struct GraphViewModePicker: View {
    @Bindable var model: GraphModel

    /// Floats over the graph so the bar keeps the graph's title.
    var body: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $model.mode) {
                Text(verbatim: "3D").tag(GraphViewMode.globe)
                Text(verbatim: "2D").tag(GraphViewMode.plane)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("graph-view-mode")

            if model.mode == .globe {
                Toggle(isOn: $model.autoRotate) {
                    Label("Auto-Rotate", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(model.autoRotate ? "Turn off auto-rotate" : "Turn on auto-rotate")
                .accessibilityIdentifier("graph-auto-rotate")
                .sensoryFeedback(.selection, trigger: model.autoRotate)
            }
        }
    }
}

struct GraphCameraButtons: View {
    let model: GraphModel
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            cameraButton("Zoom In", systemImage: "plus", identifier: "graph-zoom-in") { model.animateCamera(to: model.camera.zoomed(by: 1.5), duration: 0.2) }
            Divider().frame(width: 28)
            cameraButton("Zoom Out", systemImage: "minus", identifier: "graph-zoom-out") { model.animateCamera(to: model.camera.zoomed(by: 1 / 1.5), duration: 0.2) }
            Divider().frame(width: 28)
            cameraButton("Reset View", systemImage: "arrow.counterclockwise", identifier: "graph-reset-view") { model.resetCamera() }
        }
        .platformGlassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cameraButton(_ title: LocalizedStringKey, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            onTap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// Floats query selection controls over the canvas.
struct GraphQueryBar: View {
    let model: GraphModel
    let selection: GraphSelection
    @Binding var queryExpanded: Bool
    let onTap: () -> Void
    let editQuery: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                onTap()
                withAnimation(.easeInOut(duration: 0.2)) { queryExpanded.toggle() }
            } label: {
                HStack {
                    Label("Query", systemImage: "line.3.horizontal.decrease.circle")
                    Spacer(minLength: 0)
                    Image(systemName: queryExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(queryExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide query controls")
            .accessibilityIdentifier("graph-selection-disclosure")

            if queryExpanded {
                Text("\(selection.nodeIds.count) nodes, \(selection.edgeIds.count) edges")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("graph-selection-count")

                if let query = selection.query {
                    Button {
                        onTap()
                        editQuery()
                    } label: {
                        HStack(spacing: 10) {
                            Text(query)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("View and edit full query")
                    .accessibilityLabel("Edit query")
                    .accessibilityValue(query)
                    .accessibilityIdentifier("graph-selection-edit-query")
                }

                Divider()
                HStack(spacing: 12) {
                    Text("Show")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Show", selection: Binding(get: { selection.mode }, set: {
                        onTap()
                        model.setSelectionMode($0)
                    })) {
                        Text("Highlight").tag(GraphSelectionMode.highlight)
                        Text("Only").tag(GraphSelectionMode.isolate)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("graph-selection-mode")
                }
                Button("Clear Query") {
                    onTap()
                    model.select(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Clear query and show all nodes")
                .accessibilityIdentifier("graph-selection-clear")
            }
        }
        .padding(12)
        .frame(width: queryExpanded ? 220 : 120)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
