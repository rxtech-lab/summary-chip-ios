import simd
import SummaryKit
import SwiftUI

/// Node colours: its own, else a stable colour per type.
enum GraphPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .red, .indigo, .mint, .brown]

    static func color(for node: GraphNode) -> Color {
        if let color = Color(graphHex: node.color) { return color }
        guard let type = node.types.first else { return .accentColor }
        // FNV-1a: `hashValue` changes between launches.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in type.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

extension Color {
    init?(graphHex hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// Draws the graph and takes its gestures: a drag spins the globe or pans the plane, a pinch zooms,
/// a tap picks a node or edge. Everything is projected by hand so a popover can point at an element.
struct GraphCanvasView: View {
    @Bindable var model: GraphModel
    let document: GraphDocument
    let onTap: (GraphElementRef?, CGSize) -> Void
    @State private var dragStart: GraphCamera?
    @State private var pinchStart: GraphCamera?
    @State private var thumbnails = GraphThumbnails()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas(rendersAsynchronously: false) { context, size in
                GraphRenderer(
                    document: document,
                    positions: model.positions,
                    camera: model.camera,
                    visibility: model.visibility,
                    inspected: model.inspected,
                    thumbnails: thumbnails.images
                ).draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                onTap(model.hit(at: point, in: size), size)
            }
            .gesture(drag(size: size))
            .simultaneousGesture(pinch)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Graph"))
            .accessibilityIdentifier("graph-canvas")
            .accessibilityChildren { accessibleElements(size: size) }
            .task(id: imageURLs) { await thumbnails.load(imageURLs) }
        }
    }

    /// Only the first picture of each node, and not for huge graphs: they're small on screen.
    private var imageURLs: [URL] {
        guard document.nodes.count <= GraphThumbnails.maxNodes else { return [] }
        return document.nodes.compactMap { $0.images.first?.url }
    }

    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil {
                    model.stopCamera()
                    dragStart = model.camera
                }
                if let dragStart { model.camera = dragStart.dragged(by: value.translation, in: size) }
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil {
                    model.stopCamera()
                    pinchStart = model.camera
                }
                if let pinchStart { model.camera.zoom = pinchStart.zoomed(by: value.magnification).zoom }
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// VoiceOver and UI tests reach the elements drawn in the canvas; the Elements sheet lists them all.
    @ViewBuilder
    private func accessibleElements(size: CGSize) -> some View {
        if document.nodes.count <= 100 {
            ForEach(document.nodes.filter { model.visibility.shows(node: $0.id) }) { node in
                if let position = model.positions[node.id] {
                    let projection = model.camera.project(position, in: size)
                    if projection.depth >= -0.1 {
                        Button(node.label) { onTap(.node(node.id), size) }
                            .frame(width: 32, height: 32)
                            .position(projection.point)
                            .accessibilityIdentifier("graph-node-\(node.id)")
                    }
                }
            }
        }
    }
}

/// The first picture of each node, small enough to draw every frame.
@Observable
final class GraphThumbnails {
    static let maxNodes = 200
    private static let pixelSize = 96
    private(set) var images: [URL: Image] = [:]

    func load(_ urls: [URL]) async {
        for url in Set(urls) where images[url] == nil {
            guard !Task.isCancelled else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: Self.pixelSize,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { continue }
            images[url] = Image(decorative: image, scale: 2)
        }
    }
}

/// One frame of the graph.
struct GraphRenderer {
    let document: GraphDocument
    let positions: [String: SIMD3<Double>]
    let camera: GraphCamera
    let visibility: GraphVisibility
    let inspected: GraphElementRef?
    let thumbnails: [URL: Image]

    private static let maxLabels = 80
    /// Above this many edges they're drawn without arrowheads, to keep the frame rate.
    private static let detailedEdgeLimit = 800

    func draw(in context: inout GraphicsContext, size: CGSize) {
        var degrees: [String: Int] = [:]
        for edge in document.edges {
            degrees[edge.source, default: 0] += 1
            degrees[edge.target, default: 0] += 1
        }
        drawEdges(in: &context, size: size, degrees: degrees)
        drawNodes(in: &context, size: size, degrees: degrees)
    }

    private func drawEdges(in context: inout GraphicsContext, size: CGSize, degrees: [String: Int]) {
        // One path per style: stroking thousands of separate paths would drop frames.
        var front = Path()
        var back = Path()
        var dim = Path()
        var standing = Path()
        var inspectedPath = Path()
        var arrowsFront = Path()
        var arrowsStanding = Path()
        let detailed = document.edges.count <= Self.detailedEdgeLimit
        var labels = 0
        let labelsAllowed = document.edges.count <= 30 || camera.zoom >= 2

        for edge in document.edges where visibility.shows(edge: edge.id) {
            guard let a = positions[edge.source], let b = positions[edge.target] else { continue }
            let start = camera.project(a, in: size)
            let end = camera.project(b, in: size)
            let isInspected = inspected == .edge(edge.id)
            let stands = visibility.stands(edge: edge.id)
            let dims = visibility.dims(edge: edge.id)
            var line = Path()
            line.move(to: start.point)
            line.addLine(to: end.point)
            if isInspected { inspectedPath.addPath(line) }
            else if stands { standing.addPath(line) }
            else if dims { dim.addPath(line) }
            else if start.depth + end.depth < 0 { back.addPath(line) }
            else { front.addPath(line) }
            if detailed, edge.directed, end.depth >= 0 {
                let arrow = arrowhead(from: start.point, to: end.point, inset: radius(degree: degrees[edge.target] ?? 0, projection: end))
                if stands || isInspected { arrowsStanding.addPath(arrow) } else if !dims { arrowsFront.addPath(arrow) }
            }
            if isInspected || (labelsAllowed && !dims && labels < Self.maxLabels), start.depth + end.depth >= 0 {
                labels += 1
                let middle = CGPoint(x: (start.point.x + end.point.x) / 2, y: (start.point.y + end.point.y) / 2)
                context.draw(Text(edge.label).font(.caption2).foregroundStyle(stands || isInspected ? Color.accentColor : .secondary), at: middle)
            }
        }
        context.stroke(dim, with: .color(.primary.opacity(0.05)), lineWidth: 0.7)
        context.stroke(back, with: .color(.primary.opacity(0.07)), lineWidth: 0.7)
        context.stroke(front, with: .color(.primary.opacity(0.32)), lineWidth: 1)
        context.fill(arrowsFront, with: .color(.primary.opacity(0.4)))
        context.stroke(standing, with: .color(.accentColor), lineWidth: 2.2)
        context.fill(arrowsStanding, with: .color(.accentColor))
        context.stroke(inspectedPath, with: .color(.accentColor), lineWidth: 3.2)
    }

    private func arrowhead(from: CGPoint, to: CGPoint, inset: Double) -> Path {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        var path = Path()
        guard length > 1 else { return path }
        let ux = dx / length
        let uy = dy / length
        let tip = CGPoint(x: to.x - ux * inset, y: to.y - uy * inset)
        let base = CGPoint(x: tip.x - ux * 7, y: tip.y - uy * 7)
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * 3.5, y: base.y + ux * 3.5))
        path.addLine(to: CGPoint(x: base.x + uy * 3.5, y: base.y - ux * 3.5))
        path.closeSubpath()
        return path
    }

    private func radius(degree: Int, projection: GraphProjection) -> Double {
        (6.5 + min(Double(degree), 10) * 0.55) * projection.scale * min(camera.zoom.squareRoot(), 2.4)
    }

    private func drawNodes(in context: inout GraphicsContext, size: CGSize, degrees: [String: Int]) {
        var items: [(node: GraphNode, projection: GraphProjection)] = []
        items.reserveCapacity(document.nodes.count)
        for node in document.nodes where visibility.shows(node: node.id) {
            guard let position = positions[node.id] else { continue }
            items.append((node, camera.project(position, in: size)))
        }
        // Far side first, so nearer nodes cover it.
        items.sort { $0.projection.depth < $1.projection.depth }
        var labels = 0
        let labelsAllowed = items.count <= 60 || camera.zoom >= 2

        for (node, projection) in items {
            let radius = radius(degree: degrees[node.id] ?? 0, projection: projection)
            let bounds = CGRect(x: projection.point.x - radius, y: projection.point.y - radius, width: radius * 2, height: radius * 2)
            guard bounds.insetBy(dx: -80, dy: -40).intersects(CGRect(origin: .zero, size: size)) else { continue }
            let stands = visibility.stands(node: node.id)
            let dims = visibility.dims(node: node.id)
            let isInspected = inspected == .node(node.id)
            let isBack = projection.depth < 0
            // A picked node stays easy to see even on the far side of the globe.
            let opacity = dims ? 0.14 : isBack ? (stands || isInspected ? 0.8 : 0.28 + 0.4 * (1 + projection.depth)) : 1
            let circle = Path(ellipseIn: bounds)
            var layer = context
            layer.opacity = opacity
            if stands || isInspected {
                let halo = Path(ellipseIn: bounds.insetBy(dx: -5, dy: -5))
                layer.fill(halo, with: .color(Color.accentColor.opacity(isInspected ? 0.35 : 0.22)))
            }
            layer.fill(circle, with: .color(GraphPalette.color(for: node)))
            if radius >= 10, let url = node.images.first?.url, let image = thumbnails[url] {
                var clipped = layer
                clipped.clip(to: circle)
                clipped.draw(image, in: bounds)
            }
            layer.stroke(circle, with: .color(isInspected || stands ? .accentColor : .white.opacity(0.7)), lineWidth: isInspected ? 2.5 : stands ? 2 : 0.8)
            if !dims, isInspected || stands || (!isBack && labelsAllowed && labels < Self.maxLabels) {
                labels += 1
                let text = Text(node.label).font(.caption2.weight(stands || isInspected ? .semibold : .regular)).foregroundStyle(.primary)
                layer.draw(text, at: CGPoint(x: projection.point.x, y: projection.point.y + radius + 9))
            }
        }
    }
}
