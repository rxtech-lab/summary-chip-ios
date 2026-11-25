#if os(visionOS)
import RealityKit
import simd
import SummaryKit
import SwiftUI

struct SpatialGraphView: View {
    let environment: AppEnvironment
    let graphID: String
    @State private var model: GraphModel
    @State private var selected: GraphNode?
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @State private var zoom = 1.0
    @State private var showsVoice = false
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification = 1.0

    init(environment: AppEnvironment, graphID: String) {
        self.environment = environment
        self.graphID = graphID
        _model = State(initialValue: GraphModel(id: graphID, api: environment.api))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let document = model.document {
                    ForEach(document.edges) { edge in
                        if let source = model.positions[edge.source], let target = model.positions[edge.target] {
                            let delta = (target - source) * 180
                            let midpoint = (source + target) * 90
                            Rectangle()
                                .fill(.secondary.opacity(0.5))
                                .frame(width: max(1, simd_length(delta)), height: 2)
                                .rotation3DEffect(.radians(-atan2(delta.z, hypot(delta.x, delta.y))), axis: (x: 0, y: 1, z: 0))
                                .rotation3DEffect(.radians(atan2(delta.y, delta.x)), axis: (x: 0, y: 0, z: 1))
                                .offset(x: midpoint.x, y: midpoint.y)
                                .offset(z: midpoint.z)
                                .allowsHitTesting(false)
                        }
                    }
                    ForEach(document.nodes) { node in
                        let position = model.positions[node.id] ?? .zero
                        Button { selected = node } label: {
                            VStack {
                                Image(systemName: "circle.fill").font(.largeTitle)
                                    .foregroundStyle(GraphPalette.color(for: node))
                                Text(node.label).lineLimit(2).padding(8).glassBackgroundEffect()
                            }
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                        .offset(x: position.x * 180, y: position.y * 180)
                        .offset(z: position.z * 180)
                    }
                } else if let error = model.loadError {
                    ContentUnavailableView("Couldn’t load graph", systemImage: "exclamationmark.triangle", description: Text(error))
                } else { ProgressView("Loading graph…") }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(min(3, max(0.3, zoom * magnification)))
            .rotation3DEffect(.degrees(yaw + drag.width / 3), axis: (x: 0, y: 1, z: 0))
            .rotation3DEffect(.degrees(pitch - drag.height / 3), axis: (x: 1, y: 0, z: 0))
            .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in yaw += value.translation.width / 3; pitch -= value.translation.height / 3 })
            .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = min(3, max(0.3, zoom * value.magnification)) })
        }
        .navigationTitle(model.document?.title ?? "Graph")
        .toolbar {
            Button("Reset view", systemImage: "arrow.counterclockwise") { yaw = 0; pitch = 0; zoom = 1 }
            Button("Live voice", systemImage: "waveform") { showsVoice = true }
        }
        .sheet(isPresented: $showsVoice) {
            SpatialVoiceView(environment: environment, graph: GraphChat(id: graphID), onUpdated: { Task { await model.load() } })
        }
        .sheet(item: $selected) { node in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(node.label).font(.largeTitle)
                        ForEach(node.properties.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: String(describing: node.properties[key]!))
                        }
                    }.padding(24)
                }
                .navigationTitle("Node")
                .toolbar { Button("Done") { selected = nil } }
            }.frame(width: 500, height: 500)
        }
        .task { await model.load() }
    }
}
#endif

#if os(visionOS)
/// All windows for a graph share its camera, selection and document.
@MainActor
@Observable
final class SpatialGraphSessions {
    static let shared = SpatialGraphSessions()
    private var models: [String: GraphModel] = [:]
    var openGraphIDs: Set<String> = []

    func model(id: String, environment: AppEnvironment) -> GraphModel {
        if let model = models[id] { return model }
        let model = GraphModel(id: id, api: environment.api)
        models[id] = model
        return model
    }
}

struct SpatialGraphLauncher: View {
    let graphID: String
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ProgressView("Opening graph…")
            .task {
                SpatialGraphSessions.shared.openGraphIDs.insert(graphID)
                openWindow(id: "graph-canvas", value: graphID)
                dismiss()
                dismissWindow(id: "main")
            }
    }
}

struct SpatialGraphWindows: SwiftUI.Scene {
    let environment: AppEnvironment
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some SwiftUI.Scene {
        WindowGroup("Live voice", id: "live-voice", for: String.self) { $id in
            if let id, let content = SpatialVoiceSessions.shared.views[id] {
                content
                    .onDisappear {
                        if let graph = content.graph, SpatialGraphSessions.shared.openGraphIDs.contains(graph.id) {
                            openWindow(id: "graph-controls", value: graph.id)
                        }
                        SpatialVoiceSessions.shared.views[id] = nil
                    }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 600, height: 650)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            let size = CGSize(width: 600, height: 650)
            if let graph = context.windows.first(where: { $0.id == "graph-canvas" }) {
                return WindowPlacement(.leading(graph), size: size)
            }
            if let controls = context.windows.first(where: { $0.id == "graph-controls" }) {
                return WindowPlacement(.trailing(controls), size: size)
            }
            return WindowPlacement(.utilityPanel, size: size)
        }

        WindowGroup("Graph", id: "graph-canvas", for: String.self) { $id in
            if let id {
                graph(id, panel: "canvas")
                    .background {
                        SpatialGraphNebula()
                            .scaleEffect(0.7)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button("Done") { closeGraph(id) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("spatial-graph-done")
                            .padding(24)
                    }
                    .task {
                        SpatialGraphSessions.shared.openGraphIDs.insert(id)
                        openWindow(id: "graph-controls", value: id)
                        dismissWindow(id: "main")
                    }
                    .onDisappear { finishGraph(id) }
            }
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1, height: 1, depth: 1, in: .meters)

        WindowGroup("Node", id: "graph-node", for: SpatialGraphNodeID.self) { $selection in
            if let selection {
                SpatialGraphNodeWindow(environment: environment, selection: selection)
            }
        }
        .defaultSize(width: 480, height: 560)

        WindowGroup("Graph Controls", id: "graph-controls", for: String.self) { $id in
            if let id {
                if let voiceID = SpatialVoiceSessions.shared.graphSessions[id],
                   let voiceContent = SpatialVoiceSessions.shared.views[voiceID] {
                    graphVoiceContent(voiceContent, graphID: id, voiceID: voiceID)
                } else {
                    graph(id, panel: "controls")
                        .frame(width: 480)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.primary)
                        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 28))
                }
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 480, height: 280)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            if let graph = context.windows.first(where: { $0.id == "graph-canvas" }) {
                return WindowPlacement(.leading(graph), size: CGSize(width: 480, height: 280))
            }
            return WindowPlacement()
        }


    }

    private func graphVoiceContent(_ content: SpatialVoiceContent, graphID: String, voiceID: String) -> some View {
        var content = content
        content.onClose = {
            SpatialVoiceSessions.shared.graphSessions[graphID] = nil
            SpatialVoiceSessions.shared.views[voiceID] = nil
        }
        return content
    }

    private func closeGraph(_ id: String) {
        finishGraph(id)
        dismissWindow(id: "graph-canvas", value: id)
    }

    private func finishGraph(_ id: String) {
        guard SpatialGraphSessions.shared.openGraphIDs.remove(id) != nil else { return }
        dismissWindow(id: "graph-controls", value: id)
        if let voiceID = SpatialVoiceSessions.shared.graphSessions.removeValue(forKey: id) {
            SpatialVoiceSessions.shared.views[voiceID] = nil
        }
        let voiceIDs = SpatialVoiceSessions.shared.views.compactMap { key, content in
            content.graph?.id == id ? key : nil
        }
        for voiceID in voiceIDs {
            dismissWindow(id: "live-voice", value: voiceID)
        }
        if SpatialGraphSessions.shared.openGraphIDs.isEmpty {
            openWindow(id: "main")
        }
    }

    private func graph(_ id: String, panel: String) -> some View {
        GraphDetailView(environment: environment, graphID: id,
                        sharedModel: SpatialGraphSessions.shared.model(id: id, environment: environment),
                        spatialPanel: panel)
            .environment(\.summaryAssetLoader, environment.assetLoader)
    }
}
/// Soft cloud layers occupy separate depths, leaving no rectangular panel edge.
private struct SpatialGraphNebula: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<9) { index in
                    let angle = Double(index) * 2.399
                    let spread = index == 0 ? 0.0 : 0.22
                    Ellipse()
                        .fill(RadialGradient(
                            colors: [Color.black.opacity(0.85),
                                     (index.isMultiple(of: 2) ? Color.indigo : Color.purple).opacity(0.24),
                                     .clear],
                            center: .center, startRadius: 0,
                            endRadius: geometry.size.width * 0.36))
                        .frame(width: geometry.size.width * 0.9, height: geometry.size.height * 0.85)
                        .blur(radius: 24)
                        .rotationEffect(.degrees(Double(index) * 27))
                        .offset(x: cos(angle) * geometry.size.width * spread,
                                y: sin(angle) * geometry.size.height * spread)
                        .offset(z: -30 - Double(index) * 12)
                }
                ForEach(0..<48) { index in
                    Circle()
                        .fill(.white.opacity(index.isMultiple(of: 3) ? 0.55 : 0.22))
                        .frame(width: index.isMultiple(of: 5) ? 3 : 1.5,
                               height: index.isMultiple(of: 5) ? 3 : 1.5)
                        .blur(radius: index.isMultiple(of: 5) ? 1 : 0)
                        .offset(x: (Double((index * 73) % 101) / 100 - 0.5) * geometry.size.width * 0.85,
                                y: (Double((index * 37) % 97) / 96 - 0.5) * geometry.size.height * 0.85)
                        .offset(z: -25 - Double(index % 6) * 18)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
struct SpatialGraphNodeID: Codable, Hashable {
    let graphID: String
    let nodeID: String
}

private struct SpatialGraphNodeWindow: View {
    let environment: AppEnvironment
    let selection: SpatialGraphNodeID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var inspected: GraphElementRef?

    var body: some View {
        let model = SpatialGraphSessions.shared.model(id: selection.graphID, environment: environment)
        NavigationStack {
            ScrollView {
                GraphInspectorContent(model: model, element: inspected ?? .node(selection.nodeID)) { next in
                    if case .node(let nodeID) = next {
                        openWindow(id: "graph-node", value: SpatialGraphNodeID(graphID: selection.graphID, nodeID: nodeID))
                    } else {
                        inspected = next
                    }
                }
                .padding(20)
            }
            .navigationTitle(model.node(selection.nodeID)?.label ?? "Node")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.summaryAssetLoader, environment.assetLoader)
    }
}
#endif

#if os(visionOS)
/// Real geometry gives each eye its own perspective, including when walking around the graph.
struct SpatialGraphRealityView: View {
    @Bindable var model: GraphModel
    let document: GraphDocument
    let onTap: (GraphElementRef?, CGSize) -> Void
    @State private var dragStart: simd_quatd?
    @State private var initialZoom: Double?
    @State private var scene = SpatialGraphEntityCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            RealityView { content in
                updateGraph()
                content.add(scene.container)
            } update: { content in
                updateGraph()
            }
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                let name = value.entity.name
                if name.hasPrefix("node:") {
                    onTap(.node(String(name.dropFirst(5))), geometry.size)
                } else if name.hasPrefix("edge:") {
                    onTap(.edge(String(name.dropFirst(5))), geometry.size)
                }
            })
            .simultaneousGesture(DragGesture().targetedToAnyEntity()
                .onChanged { value in
                    model.stopCamera()
                    if dragStart == nil { dragStart = model.camera.rotation }
                    let yaw = simd_quatd(angle: Double(value.translation.width) / 200, axis: [0, 1, 0])
                    let pitch = simd_quatd(angle: Double(value.translation.height) / 200, axis: [1, 0, 0])
                    model.camera.rotation = yaw * pitch * (dragStart ?? model.camera.rotation)
                }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture().targetedToAnyEntity().onChanged { value in
                model.stopCamera()
                if initialZoom == nil { initialZoom = model.camera.zoom }
                model.camera.zoom = min(2, max(0.3, (initialZoom ?? 1) * value.gestureValue.magnification))
            }.onEnded { _ in initialZoom = nil })
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    if !reduceMotion && scenePhase == .active && model.autoRotate && dragStart == nil && initialZoom == nil {
                        model.rotateAutomatically(seconds: 0.033)
                    }
                }
            }
        }
    }

    private func updateGraph() {
        let visibleNodes = document.nodes.filter { model.visibility.shows(node: $0.id) }.map(\.id)
        let visibleEdges = document.edges.filter { model.visibility.shows(edge: $0.id) }.map(\.id)
        if scene.document != document || scene.positions != model.positions
            || scene.visibleNodes != visibleNodes || scene.visibleEdges != visibleEdges {
            scene.graph.children.removeAll()
            let geometry = makeGraph()
            scene.graph.addChild(geometry)
            scene.document = document
            scene.positions = model.positions
            scene.visibleNodes = visibleNodes
            scene.visibleEdges = visibleEdges
        }
        scene.graph.orientation = simd_quatf(vector: SIMD4<Float>(model.camera.rotation.vector))
        scene.graph.scale = SIMD3(repeating: Float(min(2, max(0.3, model.camera.zoom))))
    }

    private func makeGraph() -> Entity {
        let root = Entity()
        func position(_ id: String) -> SIMD3<Float> {
            let point = model.positions[id] ?? .zero
            return SIMD3(Float(point.x), -Float(point.y), Float(point.z)) * 0.4
        }
        for node in document.nodes where model.visibility.shows(node: node.id) {
            let sphere = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [
                SimpleMaterial(color: UIColor(GraphPalette.color(for: node)), isMetallic: false)
            ])
            sphere.name = "node:" + node.id
            sphere.position = position(node.id)
            sphere.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.035)]))
            sphere.components.set(InputTargetComponent())
            sphere.components.set(HoverEffectComponent())
            root.addChild(sphere)
            let label = ModelEntity(mesh: .generateText(node.label, extrusionDepth: 0.1,
                font: .systemFont(ofSize: 12), containerFrame: .zero, alignment: .center,
                lineBreakMode: .byTruncatingTail), materials: [UnlitMaterial(color: .white)])
            label.scale = SIMD3(repeating: 0.0015)
            label.position = sphere.position + SIMD3(0.026, 0, 0)
            root.addChild(label)
        }
        for edge in document.edges where model.visibility.shows(edge: edge.id) {
            guard model.positions[edge.source] != nil, model.positions[edge.target] != nil else { continue }
            let start = position(edge.source), end = position(edge.target)
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.0001 else { continue }
            let rod = ModelEntity(mesh: .generateBox(size: [0.002, length, 0.002], cornerRadius: 0.001),
                                  materials: [SimpleMaterial(color: .gray, isMetallic: false)])
            rod.name = "edge:" + edge.id
            rod.position = (start + end) / 2
            rod.orientation = simd_quatf(from: [0, 1, 0], to: delta / length)
            rod.generateCollisionShapes(recursive: false)
            rod.components.set(InputTargetComponent())
            root.addChild(rod)
        }
        return root
    }
}
#endif

#if os(visionOS)
/// Preserve entity identities during camera updates so an active gesture keeps its target.
@MainActor
private final class SpatialGraphEntityCache {
    let container = Entity()
    let graph = Entity()
    var document: GraphDocument?
    var positions: [String: SIMD3<Double>] = [:]
    var visibleNodes: [String] = []
    var visibleEdges: [String] = []

    init() {
        container.addChild(graph)
        // A broad target behind the graph lets users start a drag or pinch between nodes.
        let surface = Entity()
        surface.position.z = -0.48
        surface.components.set(CollisionComponent(shapes: [.generateBox(size: [0.96, 0.96, 0.01])]))
        surface.components.set(InputTargetComponent())
        container.addChild(surface)
    }
}
#endif
