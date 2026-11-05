import CoreGraphics
import Foundation
import simd

/// How a graph is laid out and turned.
public enum GraphViewMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Nodes arranged around an invisible sphere you can spin.
    case globe
    /// Nodes on a plane you can pan.
    case plane

    public var id: String { rawValue }
}

/// Node positions: unit vectors on the sphere for `.globe`, on a density-scaled plane with z = 0 for `.plane`.
/// Deterministic, so a graph looks the same each time it opens; `previous` keeps existing nodes
/// nearby after an edit instead of reshuffling the graph.
public enum GraphLayout {
    public static func positions(
        nodeIDs: [String],
        edges: [(source: String, target: String)],
        mode: GraphViewMode,
        previous: [String: SIMD3<Double>] = [:]
    ) -> [String: SIMD3<Double>] {
        let count = nodeIDs.count
        guard count > 0 else { return [:] }
        if count == 1 { return [nodeIDs[0]: previous[nodeIDs[0]] ?? (mode == .globe ? SIMD3(0, 0, 1) : .zero)] }
        // Nothing new to place: an edit to an element's data doesn't move the graph.
        if nodeIDs.allSatisfy({ previous[$0] != nil }) { return Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, previous[$0]!) }) }
        var index: [String: Int] = [:]
        for (position, id) in nodeIDs.enumerated() { index[id] = position }
        let links = edges.compactMap { edge -> (Int, Int)? in
            guard let a = index[edge.source], let b = index[edge.target], a != b else { return nil }
            return (a, b)
        }
        let order = connectedOrder(count: count, links: links)
        var points = [SIMD3<Double>](repeating: .zero, count: count)
        for (rank, node) in order.enumerated() {
            points[node] = previous[nodeIDs[node]] ?? seed(rank: rank, count: count, mode: mode)
        }
        // A small edit only needs to settle the new nodes; a fresh layout untangles from scratch.
        let budget = iterations(count: count, isRefinement: nodeIDs.contains { previous[$0] != nil })
        switch mode {
        case .globe: relaxOnSphere(&points, links: links, iterations: budget)
        case .plane: relaxOnPlane(&points, links: links, iterations: budget)
        }
        var result: [String: SIMD3<Double>] = [:]
        for (position, id) in nodeIDs.enumerated() { result[id] = points[position] }
        return result
    }

    private static func iterations(count: Int, isRefinement: Bool) -> Int {
        let affordable = 30_000_000 / max(count * count, 1)
        return min(isRefinement ? 40 : 160, max(isRefinement ? 8 : 20, affordable))
    }

    /// Breadth-first by component, so connected nodes start out next to each other.
    private static func connectedOrder(count: Int, links: [(Int, Int)]) -> [Int] {
        var neighbours = [[Int]](repeating: [], count: count)
        for (a, b) in links {
            neighbours[a].append(b)
            neighbours[b].append(a)
        }
        var seen = [Bool](repeating: false, count: count)
        var order: [Int] = []
        order.reserveCapacity(count)
        let byDegree = (0..<count).sorted { neighbours[$0].count > neighbours[$1].count || (neighbours[$0].count == neighbours[$1].count && $0 < $1) }
        for start in byDegree where !seen[start] {
            seen[start] = true
            var head = order.count
            order.append(start)
            while head < order.count {
                for next in neighbours[order[head]] where !seen[next] {
                    seen[next] = true
                    order.append(next)
                }
                head += 1
            }
        }
        return order
    }

    private static func seed(rank: Int, count: Int, mode: GraphViewMode) -> SIMD3<Double> {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let angle = golden * Double(rank)
        switch mode {
        case .globe:
            let y = 1 - 2 * (Double(rank) + 0.5) / Double(count)
            let radius = (1 - y * y).squareRoot()
            return SIMD3(radius * cos(angle), y, radius * sin(angle))
        case .plane:
            let radius = ((Double(rank) + 0.5) / Double(count)).squareRoot()
            return SIMD3(radius * cos(angle), radius * sin(angle), 0)
        }
    }

    private static func relaxOnSphere(_ points: inout [SIMD3<Double>], links: [(Int, Int)], iterations: Int) {
        let count = points.count
        var forces = [SIMD3<Double>](repeating: .zero, count: count)
        let spacing = (4 * Double.pi / Double(count)).squareRoot()
        for iteration in 0..<iterations {
            let heat = 0.12 * (1 - Double(iteration) / Double(max(iterations, 1))) + 0.004
            for i in 0..<count { forces[i] = .zero }
            for i in 0..<count {
                for j in (i + 1)..<max(count, i + 1) {
                    let delta = points[i] - points[j]
                    let distanceSquared = max(simd_length_squared(delta), 1e-6)
                    let push = delta * (spacing * spacing / distanceSquared)
                    forces[i] += push
                    forces[j] -= push
                }
            }
            for (a, b) in links {
                let delta = points[b] - points[a]
                let pull = delta * (max(0, simd_length(delta) - spacing) / spacing) * 0.35
                forces[a] += pull
                forces[b] -= pull
            }
            for i in 0..<count {
                // Only the part along the surface moves the node.
                let tangent = forces[i] - points[i] * simd_dot(forces[i], points[i])
                let length = simd_length(tangent)
                if length > 1e-9 { points[i] += tangent / length * min(length * 0.02, heat) }
                points[i] = simd_normalize(points[i])
            }
        }
    }

    private static func relaxOnPlane(_ points: inout [SIMD3<Double>], links: [(Int, Int)], iterations: Int) {
        let count = points.count
        var forces = [SIMD3<Double>](repeating: .zero, count: count)
        let spacing = (4 / Double(count)).squareRoot()
        for iteration in 0..<iterations {
            let heat = 0.14 * (1 - Double(iteration) / Double(max(iterations, 1))) + 0.003
            for i in 0..<count { forces[i] = .zero }
            for i in 0..<count {
                for j in (i + 1)..<max(count, i + 1) {
                    let delta = points[i] - points[j]
                    let distanceSquared = max(simd_length_squared(delta), 1e-6)
                    let push = delta * (spacing * spacing / distanceSquared)
                    forces[i] += push
                    forces[j] -= push
                }
            }
            for (a, b) in links {
                let delta = points[b] - points[a]
                let pull = delta * (max(0, simd_length(delta) - spacing) / spacing) * 0.35
                forces[a] += pull
                forces[b] -= pull
            }
            for i in 0..<count {
                // A weak pull to the middle keeps separate components on screen.
                forces[i] -= points[i] * 0.4
                let length = simd_length(forces[i])
                if length > 1e-9 { points[i] += forces[i] / length * min(length * 0.02, heat) }
            }
        }
        let extent = points.reduce(1e-6) { max($0, max(abs($1.x), abs($1.y))) }
        // Grow the navigable world instead of squeezing every additional node into one viewport.
        let spread = max(1, sqrt(Double(count) / 18))
        points = points.map { SIMD3($0.x / extent * spread, $0.y / extent * spread, 0) }
    }
}

/// A point on screen and how it should be drawn.
public struct GraphProjection: Sendable, Hashable {
    public var point: CGPoint
    /// 1 faces the viewer, -1 is the far side of the globe; always 1 on the plane.
    public var depth: Double
    /// Perspective size factor.
    public var scale: Double
}

/// What the view is looking at. `rotation` turns the globe; `pan` moves either mode on screen.
public struct GraphCamera: Sendable, Hashable {
    public var mode: GraphViewMode
    public var rotation: simd_quatd
    public var zoom: Double
    public var pan: SIMD2<Double>

    public static let minZoom = 0.5
    public static let maxZoom = 6.0
    private static let viewerDistance = 3.2

    public init(mode: GraphViewMode, rotation: simd_quatd = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0)), zoom: Double = 1, pan: SIMD2<Double> = .zero) {
        self.mode = mode
        self.rotation = rotation
        self.zoom = zoom
        self.pan = pan
    }

    private func radius(in size: CGSize) -> Double { min(size.width, size.height) * 0.42 * zoom }

    public func project(_ position: SIMD3<Double>, in size: CGSize) -> GraphProjection {
        let centre = SIMD2(size.width / 2 + pan.x, size.height / 2 + pan.y)
        let radius = radius(in: size)
        switch mode {
        case .plane:
            return GraphProjection(point: CGPoint(x: centre.x + position.x * radius, y: centre.y - position.y * radius), depth: 1, scale: 1)
        case .globe:
            let turned = rotation.act(position)
            let perspective = Self.viewerDistance / (Self.viewerDistance - turned.z)
            return GraphProjection(
                point: CGPoint(x: centre.x + turned.x * radius * perspective, y: centre.y - turned.y * radius * perspective),
                depth: turned.z,
                scale: perspective
            )
        }
    }

    /// Spins the globe by a drag, a turn per screen of travel however far it's zoomed; pans the plane.
    public func dragged(by translation: CGSize, in size: CGSize) -> GraphCamera {
        var next = self
        switch mode {
        case .plane:
            next.pan += SIMD2(translation.width, translation.height)
        case .globe:
            let radius = max(radius(in: size), 1)
            let yaw = simd_quatd(angle: translation.width / radius, axis: SIMD3(0, 1, 0))
            let pitch = simd_quatd(angle: translation.height / radius, axis: SIMD3(1, 0, 0))
            next.rotation = simd_normalize(yaw * pitch * rotation)
        }
        return next
    }

    public func zoomed(by factor: Double) -> GraphCamera {
        var next = self
        next.zoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        return next
    }

    /// Brings `position` to `anchor` (screen offset from the view's centre), at `zoom`.
    public func focused(on position: SIMD3<Double>, zoom target: Double, anchor: CGSize = .zero, in size: CGSize) -> GraphCamera {
        var next = self
        next.zoom = min(Self.maxZoom, max(Self.minZoom, target))
        switch mode {
        case .plane:
            let radius = min(size.width, size.height) * 0.42 * next.zoom
            next.pan = SIMD2(anchor.width - position.x * radius, anchor.height + position.y * radius)
        case .globe:
            let turned = rotation.act(position)
            let length = simd_length(turned)
            if length > 1e-9 {
                next.rotation = simd_normalize(simd_quatd(from: turned / length, to: SIMD3(0, 0, 1)) * rotation)
            }
            next.pan = SIMD2(anchor.width, anchor.height)
        }
        return next
    }

    /// Frames a group with padding, keeping its projected bounds at the viewport centre.
    public func centered(on points: [SIMD3<Double>], in size: CGSize) -> GraphCamera {
        guard !points.isEmpty, size.width > 0, size.height > 0 else { return self }
        let middle = points.reduce(.zero, +) / Double(points.count)
        var next = focused(on: middle, zoom: 1, in: size)
        let projected = points.map { next.project($0, in: size).point }
        let minX = projected.map(\.x).min()!, maxX = projected.map(\.x).max()!
        let minY = projected.map(\.y).min()!, maxY = projected.map(\.y).max()!
        let fit = min(size.width * 0.75 / max(maxX - minX, 1), size.height * 0.75 / max(maxY - minY, 1))
        next.zoom = min(2.2, max(Self.minZoom, fit))
        let boundsCentre = SIMD2((minX + maxX) / 2 - size.width / 2, (minY + maxY) / 2 - size.height / 2)
        next.pan = (next.pan - boundsCentre) * next.zoom
        return next
    }

    /// The camera `t` of the way (0…1) to `other`.
    public func interpolated(to other: GraphCamera, t: Double) -> GraphCamera {
        var next = other
        next.rotation = simd_slerp(rotation, other.rotation, t)
        next.zoom = exp(log(zoom) + (log(other.zoom) - log(zoom)) * t)
        next.pan = pan + (other.pan - pan) * t
        return next
    }
}

/// Which elements stay visible and which stand out, given a selection.
public struct GraphVisibility: Sendable {
    public let selection: GraphSelection?
    public let selectedNodes: Set<String>
    public let selectedEdges: Set<String>
    private let endpointNodes: Set<String>

    public init(document: GraphDocument, selection: GraphSelection?) {
        self.selection = selection
        selectedNodes = Set(selection?.nodeIds ?? [])
        selectedEdges = Set(selection?.edgeIds ?? [])
        // An edge picked on its own still needs its ends drawn.
        var ends = Set<String>()
        if !selectedEdges.isEmpty {
            for edge in document.edges where selectedEdges.contains(edge.id) {
                ends.insert(edge.source)
                ends.insert(edge.target)
            }
        }
        endpointNodes = ends
    }

    public func shows(node id: String) -> Bool {
        selection?.mode != .isolate || selectedNodes.contains(id) || endpointNodes.contains(id)
    }

    public func shows(edge id: String) -> Bool {
        selection?.mode != .isolate || selectedEdges.contains(id)
    }

    public func stands(node id: String) -> Bool { selectedNodes.contains(id) }
    public func stands(edge id: String) -> Bool { selectedEdges.contains(id) }
    public func dims(node id: String) -> Bool { selection != nil && !selectedNodes.contains(id) && !endpointNodes.contains(id) }
    public func dims(edge id: String) -> Bool { selection != nil && !selectedEdges.contains(id) }
}

/// A node or edge the user picked.
public enum GraphElementRef: Sendable, Hashable, Identifiable {
    case node(String)
    case edge(String)

    public var id: String {
        switch self {
        case .node(let id): "node:\(id)"
        case .edge(let id): "edge:\(id)"
        }
    }
}

/// Finds what's under a point: nodes win over edges, and nearer nodes over farther ones.
public enum GraphHitTest {
    public static let nodeRadius = 24.0
    public static let edgeTolerance = 12.0

    public static func element(
        at point: CGPoint,
        document: GraphDocument,
        positions: [String: SIMD3<Double>],
        camera: GraphCamera,
        visibility: GraphVisibility,
        size: CGSize
    ) -> GraphElementRef? {
        var best: (id: String, score: Double)?
        for node in document.nodes where visibility.shows(node: node.id) {
            guard let position = positions[node.id] else { continue }
            let projection = camera.project(position, in: size)
            let distance = hypot(projection.point.x - point.x, projection.point.y - point.y)
            guard distance <= nodeRadius else { continue }
            let score = distance - projection.depth * 12
            if best == nil || score < best!.score { best = (node.id, score) }
        }
        if let best { return .node(best.id) }
        var nearest: (id: String, distance: Double)?
        for edge in document.edges where visibility.shows(edge: edge.id) {
            guard let a = positions[edge.source], let b = positions[edge.target] else { continue }
            let distance = segmentDistance(point, camera.project(a, in: size).point, camera.project(b, in: size).point)
            if distance <= edgeTolerance, nearest == nil || distance < nearest!.distance {
                nearest = (edge.id, distance)
            }
        }
        return nearest.map { .edge($0.id) }
    }

    /// The point a node or edge is centred on, for zooming to it and anchoring its popover.
    public static func position(of element: GraphElementRef, document: GraphDocument, positions: [String: SIMD3<Double>]) -> SIMD3<Double>? {
        switch element {
        case .node(let id): return positions[id]
        case .edge(let id):
            guard let edge = document.edges.first(where: { $0.id == id }), let a = positions[edge.source], let b = positions[edge.target] else { return nil }
            return (a + b) / 2
        }
    }

    static func segmentDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
