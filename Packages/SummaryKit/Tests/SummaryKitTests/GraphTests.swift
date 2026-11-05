import CoreGraphics
import Foundation
import simd
import Testing
@testable import SummaryKit

@Suite struct GraphModelTests {
    @Test func decodesTheServerShapeWithDefaults() throws {
        let json = #"""
        {"id":"g","slug":"abc","revision":3,"visibility":"private","isOwner":true,"createdAt":"2026-11-04T00:00:00.000Z","updatedAt":"2026-11-04T00:00:00.000Z","shareUrl":"https://example.com/s/abc",
         "selection":{"mode":"isolate","nodeIds":["a"],"edgeIds":[],"query":null},
         "document":{"version":1,"title":"T","nodes":[{"id":"a","label":"A","properties":{"age":3,"nested":{"x":[1,true,null]}}},{"id":"b","label":"B","types":["P"],"images":[{"url":"https://example.com/b.jpg"}]}],
           "edges":[{"id":"e","source":"a","target":"b","label":"L"}],"queries":[{"id":"q","name":"Q","query":"MATCH (n) RETURN n"}]}}
        """#
        let graph = try SummaryJSON.decoder().decode(Graph.self, from: Data(json.utf8))
        #expect(graph.revision == 3)
        #expect(graph.selection?.mode == .isolate)
        #expect(graph.document.nodes[0].types.isEmpty)
        #expect(graph.document.nodes[0].properties["age"] == .number(3))
        #expect(graph.document.nodes[1].images.first?.url.absoluteString == "https://example.com/b.jpg")
        #expect(graph.document.edges[0].directed)
    }

    @Test func encodesOperationsAsTheServerExpects() throws {
        func object(_ operation: GraphOperation) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any])
        }
        let delete = try object(.deleteNode("a"))
        #expect(delete["op"] as? String == "delete")
        #expect(delete["collection"] as? String == "nodes")
        #expect(delete["id"] as? String == "a")
        let upsert = try object(.upsertEdge(GraphEdge(id: "e", source: "a", target: "b", label: "L")))
        #expect(upsert["op"] as? String == "upsert_edge")
        #expect((upsert["edge"] as? [String: Any])?["source"] as? String == "a")
        let meta = try object(.setMeta(title: "T", description: nil))
        #expect(meta["description"] is NSNull)
        #expect(try object(.upsertQuery(GraphSavedQuery(id: "q", name: "Q", query: "MATCH (n)")))["op"] as? String == "upsert_query")
    }

    @Test func makesReadableUniqueIDs() {
        #expect(GraphElementID.make(from: "Ada Lovelace", taken: []) == "ada-lovelace")
        #expect(GraphElementID.make(from: "Ada Lovelace", taken: ["ada-lovelace"]) == "ada-lovelace-2")
        #expect(GraphElementID.make(from: "Ada Lovelace", taken: ["ada-lovelace", "ada-lovelace-2"]) == "ada-lovelace-3")
        #expect(GraphElementID.make(from: "Émile", taken: []) == "emile")
        #expect(GraphElementID.make(from: "東京", taken: []) == "item")
    }

    @Test func kindRoundTrips() {
        #expect(SummaryKind(rawValue: "graph") == .graph)
        #expect(SummaryKind.graph.rawValue == "graph")
        #expect(SummaryKind.known.contains(.graph))
    }

    @Test func readsAgentSelections() {
        let selected: JSONValue = .object(["graphSelection": .object(["mode": .string("isolate"), "nodeIds": .array([.string("a")]), "edgeIds": .array([]), "query": .null])])
        #expect(ChatToolOutput.graphSelection(from: selected)??.mode == .isolate)
        let cleared: JSONValue = .object(["graphSelection": .null, "cleared": .bool(true)])
        let clearedSelection = ChatToolOutput.graphSelection(from: cleared)
        #expect(clearedSelection != nil && clearedSelection! == nil)
        #expect(ChatToolOutput.graphSelection(from: .object(["applied": .number(1)])) == nil)
        #expect(ChatToolOutput.graphSelection(from: .object(["error": .string("x"), "graphSelection": .null])) == nil)
    }
}

@Suite struct GraphLayoutTests {
    private let ring = (0..<12).map { "n\($0)" }
    private var ringEdges: [(source: String, target: String)] { (0..<12).map { ("n\($0)", "n\(($0 + 1) % 12)") } }

    @Test func globePointsLieOnTheSphereAndPlanePointsInBounds() {
        let globe = GraphLayout.positions(nodeIDs: ring, edges: ringEdges, mode: .globe)
        #expect(globe.count == 12)
        for point in globe.values { #expect(abs(simd_length(point) - 1) < 1e-6) }
        let plane = GraphLayout.positions(nodeIDs: ring, edges: ringEdges, mode: .plane)
        for point in plane.values {
            #expect(abs(point.x) <= 1 + 1e-9 && abs(point.y) <= 1 + 1e-9)
            #expect(point.z == 0)
        }
    }

    @Test func largePlaneUsesMoreNavigableSpace() {
        let ids = (0..<140).map { "n\($0)" }
        let points = GraphLayout.positions(nodeIDs: ids, edges: [], mode: .plane)
        let extent = points.values.map { max(abs($0.x), abs($0.y)) }.max()!
        #expect(extent > 1.5)
        #expect(points.values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z == 0 })
    }

    @Test func isDeterministic() {
        let first = GraphLayout.positions(nodeIDs: ring, edges: ringEdges, mode: .globe)
        let second = GraphLayout.positions(nodeIDs: ring, edges: ringEdges, mode: .globe)
        #expect(first == second)
    }

    @Test(arguments: [GraphViewMode.globe, .plane])
    func connectedNodesEndUpCloserThanStrangers(mode: GraphViewMode) {
        // Two tight clusters joined by nothing.
        let ids = (0..<20).map { "n\($0)" }
        var edges: [(source: String, target: String)] = []
        for i in 0..<10 { for j in (i + 1)..<10 { edges.append(("n\(i)", "n\(j)")); edges.append(("n\(i + 10)", "n\(j + 10)")) } }
        let points = GraphLayout.positions(nodeIDs: ids, edges: edges, mode: mode)
        func mean(_ pairs: [(Int, Int)]) -> Double {
            pairs.map { simd_distance(points["n\($0.0)"]!, points["n\($0.1)"]!) }.reduce(0, +) / Double(pairs.count)
        }
        let within = mean((0..<10).flatMap { i in ((i + 1)..<10).map { (i, $0) } })
        let across = mean((0..<10).flatMap { i in (10..<20).map { (i, $0) } })
        #expect(within < across)
    }

    @Test func keepsExistingNodesInPlaceAfterAnEdit() {
        let first = GraphLayout.positions(nodeIDs: ring, edges: ringEdges, mode: .globe)
        let same = GraphLayout.positions(nodeIDs: ring, edges: ringEdges, mode: .globe, previous: first)
        #expect(same == first)
        let added = GraphLayout.positions(nodeIDs: ring + ["new"], edges: ringEdges + [("new", "n0")], mode: .globe, previous: first)
        #expect(added["new"] != nil)
        let moved = ring.map { simd_distance(first[$0]!, added[$0]!) }.max()!
        #expect(moved < 1)
    }

    @Test func handlesEmptySingleAndDanglingInput() {
        #expect(GraphLayout.positions(nodeIDs: [], edges: [], mode: .globe).isEmpty)
        #expect(GraphLayout.positions(nodeIDs: ["a"], edges: [], mode: .globe)["a"] == SIMD3(0, 0, 1))
        #expect(GraphLayout.positions(nodeIDs: ["a", "b"], edges: [("a", "missing"), ("a", "a")], mode: .plane).count == 2)
    }

    @Test func layoutOfTheLargestGraphFinishes() {
        let ids = (0..<300).map { "n\($0)" }
        let edges: [(source: String, target: String)] = (0..<299).map { ("n\($0)", "n\($0 + 1)") }
        #expect(GraphLayout.positions(nodeIDs: ids, edges: edges, mode: .globe).count == 300)
    }
}

@Suite struct GraphCameraTests {
    private let size = CGSize(width: 400, height: 800)

    @Test func focusingBringsANodeToTheCentreFacingTheViewer() {
        let point = simd_normalize(SIMD3(0.3, -0.6, -0.7))
        let camera = GraphCamera(mode: .globe).focused(on: point, zoom: 2, in: size)
        let projection = camera.project(point, in: size)
        #expect(abs(projection.point.x - 200) < 1e-6)
        #expect(abs(projection.point.y - 400) < 1e-6)
        #expect(abs(projection.depth - 1) < 1e-6)
        #expect(camera.zoom == 2)
    }

    @Test func focusingHonoursAnAnchorInBothModes() {
        let anchor = CGSize(width: 0, height: -200)
        let point = SIMD3(0.5, 0.5, 0.0)
        let plane = GraphCamera(mode: .plane).focused(on: point, zoom: 2, anchor: anchor, in: size).project(point, in: size)
        #expect(abs(plane.point.x - 200) < 1e-6 && abs(plane.point.y - 200) < 1e-6)
        let globe = GraphCamera(mode: .globe).focused(on: simd_normalize(point), zoom: 2, anchor: anchor, in: size).project(simd_normalize(point), in: size)
        #expect(abs(globe.point.y - 200) < 1e-6)
    }

    @Test func dragsSpinTheGlobeAndPanThePlane() {
        let point = SIMD3(0.0, 0.0, 1.0)
        let globe = GraphCamera(mode: .globe)
        let before = globe.project(point, in: size).point
        let after = globe.dragged(by: CGSize(width: 40, height: 0), in: size).project(point, in: size).point
        #expect(after.x > before.x)
        let plane = GraphCamera(mode: .plane).dragged(by: CGSize(width: 40, height: -10), in: size)
        #expect(plane.pan == SIMD2(40, -10))
    }

    @Test func clampsZoomAndInterpolatesEnds() {
        #expect(GraphCamera(mode: .plane).zoomed(by: 100).zoom == GraphCamera.maxZoom)
        #expect(GraphCamera(mode: .plane).zoomed(by: 0.001).zoom == GraphCamera.minZoom)
        let start = GraphCamera(mode: .plane, zoom: 1)
        let end = GraphCamera(mode: .plane, zoom: 4, pan: SIMD2(10, 0))
        #expect(abs(start.interpolated(to: end, t: 0.5).zoom - 2) < 1e-9)
        #expect(start.interpolated(to: end, t: 1).pan == SIMD2(10, 0))
    }
}

@Suite struct GraphHitTestTests {
    private let size = CGSize(width: 400, height: 400)
    private let document = GraphDocument(
        title: "T",
        nodes: [GraphNode(id: "a", label: "A"), GraphNode(id: "b", label: "B"), GraphNode(id: "c", label: "C")],
        edges: [GraphEdge(id: "ab", source: "a", target: "b", label: "L")]
    )
    private let positions: [String: SIMD3<Double>] = ["a": SIMD3(-0.5, 0, 0), "b": SIMD3(0.5, 0, 0), "c": SIMD3(0, 0.8, 0)]
    private let camera = GraphCamera(mode: .plane)

    private func hit(_ point: CGPoint, selection: GraphSelection? = nil) -> GraphElementRef? {
        GraphHitTest.element(at: point, document: document, positions: positions, camera: camera, visibility: GraphVisibility(document: document, selection: selection), size: size)
    }

    @Test func findsNodesThenEdgesThenNothing() {
        let a = camera.project(positions["a"]!, in: size).point
        #expect(hit(a) == .node("a"))
        #expect(hit(CGPoint(x: 200, y: 203)) == .edge("ab"))
        #expect(hit(CGPoint(x: 10, y: 390)) == nil)
    }

    @Test func hiddenElementsCannotBeHit() {
        let c = camera.project(positions["c"]!, in: size).point
        let isolate = GraphSelection(mode: .isolate, nodeIds: ["a"])
        #expect(hit(c, selection: isolate) == nil)
        #expect(hit(CGPoint(x: 200, y: 203), selection: isolate) == nil)
        #expect(hit(c, selection: GraphSelection(mode: .highlight, nodeIds: ["a"])) == .node("c"))
    }

    @Test func prefersTheNearSideOfTheGlobe() {
        let globe = GraphCamera(mode: .globe)
        let near = SIMD3(0.0, 0.0, 1.0)
        let far = SIMD3(0.0, 0.0, -1.0)
        let doc = GraphDocument(title: "T", nodes: [GraphNode(id: "far", label: "F"), GraphNode(id: "near", label: "N")])
        let result = GraphHitTest.element(at: CGPoint(x: 200, y: 200), document: doc, positions: ["far": far, "near": near], camera: globe, visibility: GraphVisibility(document: doc, selection: nil), size: size)
        #expect(result == .node("near"))
    }

    @Test func anEdgeIsCentredBetweenItsEnds() {
        let middle = GraphHitTest.position(of: .edge("ab"), document: document, positions: positions)
        #expect(middle == SIMD3(0, 0, 0))
        #expect(GraphHitTest.position(of: .edge("missing"), document: document, positions: positions) == nil)
    }

    @Test func isolatingAnEdgeKeepsItsEnds() {
        let visibility = GraphVisibility(document: document, selection: GraphSelection(mode: .isolate, edgeIds: ["ab"]))
        #expect(visibility.shows(edge: "ab"))
        #expect(visibility.shows(node: "a") && visibility.shows(node: "b"))
        #expect(!visibility.shows(node: "c"))
        #expect(!visibility.dims(node: "a"))
        #expect(visibility.dims(node: "c"))
    }
}

@Test func centersMultipleNodesAndFitsTheirProjectedBounds() {
    let size = CGSize(width: 600, height: 400)
    for mode in [GraphViewMode.plane, .globe] {
        let points = [SIMD3<Double>(0.8, 0.5, 0.3), SIMD3<Double>(-0.4, -0.6, 0.7)]
        let camera = GraphCamera(mode: mode).centered(on: points, in: size)
        let projected = points.map { camera.project($0, in: size).point }
        #expect(abs((projected[0].x + projected[1].x) / 2 - 300) < 1e-6)
        #expect(abs((projected[0].y + projected[1].y) / 2 - 200) < 1e-6)
        #expect(projected.allSatisfy { $0.x >= 0 && $0.x <= 600 && $0.y >= 0 && $0.y <= 400 })
    }
}
