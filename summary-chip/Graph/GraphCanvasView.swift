import simd
import SummaryKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    var selectedElements: [GraphElementRef] = []
    var onSelect: (GraphElementRef?, Bool) -> Void = { _, _ in }
    let onTap: (GraphElementRef?, CGSize) -> Void
    @GestureState private var isTouching = false
    @State private var rotationResumeTime = ContinuousClock.now
    @State private var additiveSelection = false
    @State private var dragStart: GraphCamera?
    @State private var pinchStart: GraphCamera?
    @State private var thumbnails = GraphThumbnails()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var rotatesAutomatically: Bool {
        model.autoRotate && !reduceMotion && scenePhase == .active && model.mode == .globe
            && model.inspected == nil && !isTouching && dragStart == nil && pinchStart == nil
    }

    var body: some View {
        #if os(visionOS)
        SpatialGraphRealityView(model: model, document: document, onTap: { element, size in
            onSelect(element, false)
            onTap(element, size)
        })
        #else
        planarBody
        #endif
    }

    private var planarBody: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas(rendersAsynchronously: false) { context, size in
                GraphRenderer(
                    document: document,
                    positions: model.positions,
                    camera: model.camera,
                    visibility: model.visibility,
                    inspected: model.inspected,
                    thumbnails: thumbnails.images,
                    selectedElements: Set(selectedElements)
                ).draw(in: &context, size: size)
            }
            #if !os(visionOS)
            .background { GraphBackdrop(camera: model.camera).allowsHitTesting(false).accessibilityHidden(true) }
            #endif
            .contentShape(Rectangle())
            #if os(macOS)
            .background {
                GraphContextMenuSurface { point in
                    pauseAutomaticRotation()
                    guard let element = model.hit(at: point, in: size) else { return nil }
                    return { onTap(element, size) }
                }
                .accessibilityHidden(true)
            }
            #endif
            .simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .local)
                    .exclusively(before: SpatialTapGesture(count: 1, coordinateSpace: .local))
                    .onEnded { value in
                        pauseAutomaticRotation()
                        switch value {
                        case .first(let tap):
                            guard let element = model.hit(at: tap.location, in: size) else { return }
                            onTap(element, size)
                        case .second(let tap):
                            guard let element = model.hit(at: tap.location, in: size) else {
                                onSelect(nil, false)
                                return
                            }
                            #if os(macOS)
                            let additive = additiveSelection
                            #else
                            let additive = false
                            #endif
                            onSelect(element, additive)
                            guard !additive, case .node = element,
                                  let position = GraphHitTest.position(of: element, document: document, positions: model.positions) else { return }
                            let target = model.camera.focused(on: position, zoom: model.camera.zoom, in: size)
                            if reduceMotion {
                                model.stopCamera()
                                model.camera = target
                            } else {
                                model.animateCamera(to: target, duration: 0.55)
                            }
                        }
                    }
            )
            .gesture(drag(size: size))
            .simultaneousGesture(pinch)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        #if os(macOS)
                        additiveSelection = NSEvent.modifierFlags.contains(.command)
                        #endif
                    }
                    .updating($isTouching) { _, touching, _ in touching = true }
            )
            .onChange(of: model.autoRotate) { _, enabled in
                if enabled { rotationResumeTime = .now }
            }
            .onChange(of: isTouching) { _, _ in pauseAutomaticRotation() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Graph"))
            .accessibilityIdentifier("graph-canvas")
            .accessibilityChildren { accessibleElements(size: size) }
            .task(id: imageURLs) { await thumbnails.load(imageURLs) }
            .task(id: rotatesAutomatically) {
                guard rotatesAutomatically else { return }
                let clock = ContinuousClock()
                var previous = clock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(33)) }
                    catch { return }
                    let now = clock.now
                    let elapsed = previous.duration(to: now).components
                    previous = now
                    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                    guard rotatesAutomatically, now >= rotationResumeTime else { continue }
                    model.rotateAutomatically(seconds: min(seconds, 0.1))
                }
            }
        }
    }

    /// Only the first picture of each node, and not for huge graphs: they're small on screen.
    private var imageURLs: [URL] {
        guard document.nodes.count <= GraphThumbnails.maxNodes else { return [] }
        return document.nodes.compactMap { $0.images.first?.url }
    }

    private func pauseAutomaticRotation() {
        rotationResumeTime = ContinuousClock.now.advanced(by: .seconds(30))
    }

    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                pauseAutomaticRotation()
                if dragStart == nil {
                    model.stopCamera()
                    dragStart = model.camera
                }
                if let dragStart { model.camera = dragStart.dragged(by: value.translation, in: size) }
            }
            .onEnded { _ in
                dragStart = nil
                pauseAutomaticRotation()
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pauseAutomaticRotation()
                if pinchStart == nil {
                    model.stopCamera()
                    pinchStart = model.camera
                }
                if let pinchStart { model.camera.zoom = pinchStart.zoomed(by: value.magnification).zoom }
            }
            .onEnded { _ in
                pinchStart = nil
                pauseAutomaticRotation()
            }
    }

    /// VoiceOver and UI tests reach the elements drawn in the canvas; the Elements sheet lists them all.
    @ViewBuilder
    private func accessibleElements(size: CGSize) -> some View {
        if document.nodes.count <= 100 {
            ForEach(document.nodes.filter { model.visibility.shows(node: $0.id) }) { node in
                if let position = model.positions[node.id] {
                    let projection = model.camera.project(position, in: size)
                    if projection.depth >= -0.1 {
                        Button(node.label) {
                            pauseAutomaticRotation()
                            onTap(.node(node.id), size)
                        }
                            .frame(width: 32, height: 32)
                            .position(projection.point)
                            .accessibilityIdentifier("graph-node-\(node.id)")
                    }
                }
            }
        }
    }
}

/// A deterministic 3D sky: stars and nebulae share the graph's orientation.
/// Project from inside the star sphere, with a gentler zoom than the foreground graph.
private struct GraphBackdrop: View {
    let camera: GraphCamera
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Star {
        let position: SIMD3<Double>
        let brightness: Double
        let radius: Double
    }

    private static let stars: [Star] = {
        var seed: UInt64 = 0xC05505
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64.max >> 11)
        }
        return (0..<700).map { index in
            let longitude = random() * 2 * .pi
            // Most stars form a tilted Milky Way band, with a scattered outer field.
            let latitude = index < 430 ? (random() + random() - 1) * 0.22 : asin(random() * 2 - 1)
            let direction = SIMD3(cos(latitude) * cos(longitude), sin(latitude), cos(latitude) * sin(longitude))
            let tilt = simd_quatd(angle: 0.55, axis: SIMD3(0, 0, 1))
            return Star(position: tilt.act(direction), brightness: 0.25 + random() * 0.65,
                        radius: 0.5 + pow(random(), 4) * 0.65)
        }
    }()

    var body: some View {
        let dark = colorScheme == .dark
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(dark ? Color(red: 0.015, green: 0.02, blue: 0.055)
                                          : Color(red: 0.94, green: 0.955, blue: 0.985)))
            guard contrast != .increased else { return }
            let focal = max(size.width, size.height) * 0.65 * pow(camera.zoom, 0.25)
            let rotation = camera.mode == .globe ? camera.rotation : simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
            func project(_ position: SIMD3<Double>) -> (CGPoint, Double)? {
                let turned = rotation.act(position)
                guard turned.z > 0.12 else { return nil }
                return (CGPoint(x: size.width / 2 + turned.x / turned.z * focal,
                                y: size.height / 2 - turned.y / turned.z * focal), turned.z)
            }
            // Broad clouds lie on the same tilted celestial band as the stars.
            for index in 0..<24 {
                let angle = Double(index) / 24 * 2 * .pi
                let direction = simd_quatd(angle: 0.55, axis: SIMD3(0, 0, 1)).act(SIMD3(cos(angle), 0, sin(angle)))
                guard let (point, depth) = project(direction) else { continue }
                let radius = focal * 0.24 / depth
                let color: Color = index.isMultiple(of: 3) ? .purple : .cyan
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .radialGradient(Gradient(colors: [color.opacity(dark ? 0.065 : 0.035), .clear]),
                                                   center: point, startRadius: 0, endRadius: radius))
            }
            for star in Self.stars {
                guard let (point, depth) = project(star.position),
                      CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4).contains(point) else { continue }
                let radius = star.radius / sqrt(depth)
                // Leave the graph's central area quiet; the galaxy reads at the periphery.
                let distance = hypot((point.x - size.width / 2) / max(size.width / 2, 1),
                                     (point.y - size.height / 2) / max(size.height / 2, 1))
                let peripheral = 0.35 + 0.65 * min(distance * distance, 1)
                let opacity = star.brightness * (dark ? 0.6 : 0.4) * peripheral
                let color: Color = dark ? .white : .indigo
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(color.opacity(opacity)))
            }
        }
        .clipped()
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
    var selectedElements: Set<GraphElementRef> = []

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
        drawEdgeLabels(in: &context, size: size)
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

        for edge in document.edges where visibility.shows(edge: edge.id) {
            guard let a = positions[edge.source], let b = positions[edge.target] else { continue }
            let start = camera.project(a, in: size)
            let end = camera.project(b, in: size)
            let isInspected = inspected == .edge(edge.id)
            let stands = visibility.stands(edge: edge.id) || selectedElements.contains(.edge(edge.id))
            let dims = visibility.dims(edge: edge.id) && !selectedElements.contains(.edge(edge.id))
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

        }
        context.stroke(dim, with: .color(.primary.opacity(0.05)), lineWidth: 0.7)
        context.stroke(back, with: .color(.primary.opacity(0.18)), lineWidth: 0.9)
        context.stroke(front, with: .color(.primary.opacity(document.edges.count > 100 ? 0.16 : 0.30)), lineWidth: 1.2)
        context.fill(arrowsFront, with: .color(.primary.opacity(0.40)))
        context.stroke(standing, with: .color(.accentColor), lineWidth: 2.2)
        context.fill(arrowsStanding, with: .color(.accentColor))
        context.stroke(inspectedPath, with: .color(.accentColor), lineWidth: 3.2)
    }

    /// Reserve space for inspected and selected relationships before ordinary labels.
    /// Draw after all strokes so the line cannot cross through the text.
    private func drawEdgeLabels(in context: inout GraphicsContext, size: CGSize) {
        let labelsAllowed = document.edges.count <= 30 || camera.zoom >= 2
        func priority(_ edge: GraphEdge) -> Int {
            if inspected == .edge(edge.id) { return 2 }
            return selectedElements.contains(.edge(edge.id)) || visibility.stands(edge: edge.id) ? 1 : 0
        }
        let candidates = document.edges.filter { edge in
            visibility.shows(edge: edge.id)
                && (priority(edge) > 0 || (labelsAllowed && !visibility.dims(edge: edge.id)))
        }.sorted { lhs, rhs in
            let left = priority(lhs), right = priority(rhs)
            return left == right ? lhs.id < rhs.id : left > right
        }
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        var occupied: [CGRect] = []
        for edge in candidates {
            guard occupied.count < Self.maxLabels else { break }
            guard !edge.label.isEmpty,
                  let a = positions[edge.source], let b = positions[edge.target] else { continue }
            let start = camera.project(a, in: size)
            let end = camera.project(b, in: size)
            guard start.depth + end.depth >= 0 else { continue }
            let emphasized = priority(edge) > 0
            let text = context.resolve(Text(edge.label)
                .font(.caption.weight(emphasized ? .semibold : .regular))
                .foregroundStyle(Color.primary))
            let measured = text.measure(in: CGSize(width: min(240, max(1, size.width - 24)), height: 48))
            let middle = CGPoint(x: (start.point.x + end.point.x) / 2, y: (start.point.y + end.point.y) / 2)
            let bounds = CGRect(x: middle.x - measured.width / 2 - 6,
                                y: middle.y - measured.height / 2 - 4,
                                width: measured.width + 12, height: measured.height + 8)
            // Keep the label at its edge's midpoint; omit collisions rather than imply a different edge.
            guard viewport.contains(bounds), !occupied.contains(where: { $0.intersects(bounds) }) else { continue }
            occupied.append(bounds.insetBy(dx: -4, dy: -3))
            let panel = Path(roundedRect: bounds, cornerRadius: 5)
            context.fill(panel, with: .color(.graphLabelBackground))
            if emphasized { context.stroke(panel, with: .color(.accentColor), lineWidth: 1) }
            context.draw(text, in: bounds.insetBy(dx: 6, dy: 4))
        }
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
        let labelsAllowed = true
        var occupiedLabels: [CGRect] = []

        for (node, projection) in items {
            let radius = radius(degree: degrees[node.id] ?? 0, projection: projection)
            let bounds = CGRect(x: projection.point.x - radius, y: projection.point.y - radius, width: radius * 2, height: radius * 2)
            guard bounds.insetBy(dx: -80, dy: -40).intersects(CGRect(origin: .zero, size: size)) else { continue }
            let stands = visibility.stands(node: node.id) || selectedElements.contains(.node(node.id))
            let dims = visibility.dims(node: node.id) && !selectedElements.contains(.node(node.id))
            let isInspected = inspected == .node(node.id)
            let isBack = projection.depth < 0
            // A picked node stays easy to see even on the far side of the globe.
            let opacity = stands || isInspected ? 1 : dims ? 0.14 : isBack ? 0.28 + 0.4 * (1 + projection.depth) : 1
            let circle = Path(ellipseIn: bounds)
            var layer = context
            layer.opacity = opacity
            if stands || isInspected {
                let halo = Path(ellipseIn: bounds.insetBy(dx: -5, dy: -5))
                layer.fill(halo, with: .color(Color.accentColor.opacity(0.28)))
                // A distinct outer ring is shared by tap, query and agent selections.
                layer.stroke(halo, with: .color(.accentColor), lineWidth: 2)
            }
            let tint = GraphPalette.color(for: node)
            layer.fill(Path(ellipseIn: bounds.insetBy(dx: -3, dy: -3)),
                       with: .color(tint.opacity(0.10)))
            layer.fill(circle, with: .linearGradient(
                Gradient(colors: [tint.mix(with: .white, by: 0.3), tint, tint.mix(with: .black, by: 0.22)]),
                startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
            if radius >= 10, let url = node.images.first?.url, let image = thumbnails[url] {
                var clipped = layer
                clipped.clip(to: circle)
                clipped.draw(image, in: bounds)
            }
            layer.stroke(circle, with: .color(isInspected || stands ? .accentColor : .white.opacity(0.7)), lineWidth: isInspected ? 2.5 : stands ? 2 : 0.8)
            if !dims, isInspected || stands || (!isBack && labelsAllowed && labels < Self.maxLabels) {
                let text = Text(node.label).font(.caption2.weight(stands || isInspected ? .semibold : .regular)).foregroundStyle(.primary)
                let resolved = layer.resolve(text)
                let measured = resolved.measure(in: CGSize(width: 180, height: 36))
                let labelBounds = CGRect(x: projection.point.x - measured.width / 2 - 5,
                                         y: projection.point.y + radius + 4,
                                         width: measured.width + 10, height: measured.height + 6)
                guard isInspected || stands || !occupiedLabels.contains(where: { $0.intersects(labelBounds) }) else { continue }
                labels += 1
                occupiedLabels.append(labelBounds.insetBy(dx: -3, dy: -2))
                layer.fill(Path(roundedRect: labelBounds, cornerRadius: 5),
                           with: .color(Color.graphLabelBackground.opacity(0.85)))
                layer.draw(resolved, in: labelBounds.insetBy(dx: 5, dy: 3))
            }
        }
    }
}

private extension Color {
    static var graphLabelBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

#if os(macOS)
/// Observes secondary clicks without placing a native hit-testing surface above SwiftUI gestures.
private struct GraphContextMenuSurface: NSViewRepresentable {
    var actionAt: (CGPoint) -> (() -> Void)?

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.actionAt = actionAt
    }

    static func dismantleNSView(_ view: Surface, coordinator: ()) {
        view.stopMonitoring()
    }

    final class Surface: NSView {
        var actionAt: ((CGPoint) -> (() -> Void)?)?
        private var showDetails: (() -> Void)?
        override var isFlipped: Bool { true }

        private var monitor: Any?

        // Never participate in hit testing: the canvas owns all primary gestures.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          !self.isHiddenOrHasHiddenAncestor,
                          event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                          self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                    self.presentMenu(event)
                    return true
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func presentMenu(_ event: NSEvent) {
            guard let action = actionAt?(convert(event.locationInWindow, from: nil)) else { return }
            showDetails = action
            let menu = NSMenu()
            let item = NSMenuItem(title: String(localized: "Show Details"),
                                  action: #selector(openDetails), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            menu.addItem(item)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            showDetails = nil
        }

        @objc private func openDetails() {
            let action = showDetails
            // Present after the native menu has dismissed.
            DispatchQueue.main.async { action?() }
        }
    }
}
#endif
