import Foundation
import Observation
import simd
import SummaryKit

/// One graph on screen: its document, layout, camera and selection, and the saves made from the app.
@Observable
final class GraphModel {
    let id: String
    let api: SummaryAPIClient
    private(set) var graph: Graph?
    /// An old version being looked at; shown instead of the graph and read-only.
    private(set) var previewDocument: GraphDocument?
    private(set) var positions: [String: SIMD3<Double>] = [:]
    private(set) var isLaidOut = false
    private(set) var loadError: String?
    /// What's on screen as a `Saving…` overlay.
    private(set) var status: String?
    /// A brief confirmation at the top of the screen.
    private(set) var notice: String?
    var actionError: String?
    /// Haptics: bumped after every save.
    private(set) var savedCount = 0

    var mode: GraphViewMode = .globe {
        didSet {
            guard mode != oldValue else { return }
            camera = GraphCamera(mode: mode)
            positions = [:]
            isLaidOut = false
            scheduleLayout()
        }
    }
    var camera = GraphCamera(mode: .globe)
    private(set) var selection: GraphSelection?
    private(set) var visibility = GraphVisibility(document: GraphDocument(title: ""), selection: nil)
    /// The element whose info is showing.
    var inspected: GraphElementRef?

    private var layoutTask: Task<Void, Never>?
    private var cameraTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// Bumped by every local selection change; a reload that started before one mustn't undo it.
    private var selectionGeneration = 0
    private var pendingSelectionWrites = 0

    init(id: String, api: SummaryAPIClient) {
        self.id = id
        self.api = api
    }

    var document: GraphDocument? { previewDocument ?? graph?.document }
    var isOwner: Bool { graph?.isOwner ?? false }
    var canEdit: Bool { isOwner && previewDocument == nil }

    // MARK: Loading

    func load() async {
        do {
            let loaded = try await api.graph(id: id)
            adopt(loaded, selection: loaded.selection)
            loadError = nil
        } catch is CancellationError {
        } catch {
            if graph == nil { loadError = error.localizedDescription }
        }
    }

    /// An edit or selection made elsewhere (an agent) shows up; a reload that fails keeps what's on screen.
    func refresh() async {
        guard !isBusy else { return }
        let generation = selectionGeneration
        guard let loaded = try? await api.graph(id: id) else { return }
        // A viewer's selection is local, and a selection being saved is newer than this response.
        let keepsLocal = !loaded.isOwner || generation != selectionGeneration || pendingSelectionWrites > 0
        let next = keepsLocal ? selection : loaded.selection
        guard loaded.revision != graph?.revision || next != selection else { return }
        adopt(loaded, selection: next)
    }

    private var isBusy: Bool { status != nil }

    private func adopt(_ loaded: Graph, selection newSelection: GraphSelection?) {
        graph = loaded
        selection = newSelection
        visibility = GraphVisibility(document: document ?? loaded.document, selection: previewDocument == nil ? newSelection : nil)
        if case .node(let id)? = inspected, !(document?.nodes.contains { $0.id == id } ?? false) { inspected = nil }
        if case .edge(let id)? = inspected, !(document?.edges.contains { $0.id == id } ?? false) { inspected = nil }
        scheduleLayout()
    }

    func preview(_ document: GraphDocument?) {
        previewDocument = document
        inspected = nil
        visibility = GraphVisibility(document: self.document ?? GraphDocument(title: ""), selection: document == nil ? selection : nil)
        scheduleLayout()
    }

    /// Lays out off the main thread, keeping nodes that already have a place.
    private func scheduleLayout() {
        guard let document else { return }
        let ids = document.nodes.map(\.id)
        let edges = document.edges.map { (source: $0.source, target: $0.target) }
        let previous = positions
        let mode = mode
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                GraphLayout.positions(nodeIDs: ids, edges: edges, mode: mode, previous: previous)
            }.value
            guard !Task.isCancelled, let self, self.mode == mode else { return }
            self.positions = result
            self.isLaidOut = true
        }
    }

    // MARK: Saving

    /// Saves changes as one edit behind a status overlay. Returns whether it worked.
    @discardableResult
    func apply(_ operations: [GraphOperation], status message: String, done: String? = nil) async -> Bool {
        status = message
        defer { status = nil }
        do {
            let saved = try await api.updateGraph(id: id, operations: operations)
            adopt(saved, selection: selection)
            savedCount += 1
            if let done { show(notice: done) }
            return true
        } catch is CancellationError {
            return false
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    private func show(notice message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Queries and selection

    /// Runs a query and lights up what it matched. Errors (bad syntax) are thrown to the query sheet.
    func run(query: String, mode: GraphSelectionMode) async throws -> GraphQueryResult {
        status = String(localized: "Running query…")
        defer { status = nil }
        let result = try await api.queryGraph(id: id, query: query)
        if result.nodeIds.isEmpty && result.edgeIds.isEmpty { return result }
        select(GraphSelection(mode: mode, nodeIds: result.nodeIds, edgeIds: result.edgeIds, query: query))
        return result
    }

    /// Lights elements up and keeps the choice for next time.
    func select(_ newSelection: GraphSelection?) {
        apply(selection: newSelection)
        guard isOwner else { return }
        pendingSelectionWrites += 1
        Task { [weak self, api, id] in
            try? await api.setGraphSelection(id: id, selection: newSelection)
            self?.pendingSelectionWrites -= 1
        }
    }

    /// An agent's selection, already saved on the server.
    func apply(selection newSelection: GraphSelection?) {
        selectionGeneration += 1
        let isNew = newSelection?.nodeIds != selection?.nodeIds || newSelection?.edgeIds != selection?.edgeIds
        selection = newSelection
        visibility = GraphVisibility(document: document ?? GraphDocument(title: ""), selection: newSelection)
        if case .node(let id)? = inspected, !visibility.shows(node: id) { inspected = nil }
        if case .edge(let id)? = inspected, !visibility.shows(edge: id) { inspected = nil }
        if isNew { turnToSelection() }
    }

    /// Turns the globe so what was picked isn't left on the far side.
    private func turnToSelection() {
        guard mode == .globe, let selection else { return }
        let ends = (document?.edges ?? []).filter { selection.edgeIds.contains($0.id) }.flatMap { [$0.source, $0.target] }
        let points = (selection.nodeIds + ends).compactMap { positions[$0] }
        guard !points.isEmpty else { return }
        let middle = points.reduce(SIMD3<Double>.zero, +)
        guard simd_length(middle) > 1e-6 else { return }
        // A globe's rotation doesn't depend on the view's size.
        animateCamera(to: camera.focused(on: simd_normalize(middle), zoom: camera.zoom, in: .zero))
    }

    func setSelectionMode(_ mode: GraphSelectionMode) {
        guard var current = selection, current.mode != mode else { return }
        current.mode = mode
        select(current)
    }

    // MARK: Camera

    func hit(at point: CGPoint, in size: CGSize) -> GraphElementRef? {
        guard let document else { return nil }
        return GraphHitTest.element(at: point, document: document, positions: positions, camera: camera, visibility: visibility, size: size)
    }

    func stopCamera() { cameraTask?.cancel() }

    /// Eases the camera to `target`; a new gesture or focus cancels it.
    func animateCamera(to target: GraphCamera, duration: Double = 0.42) {
        cameraTask?.cancel()
        let start = camera
        cameraTask = Task { [weak self] in
            let frames = max(Int(duration * 60), 1)
            for frame in 1...frames {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                let t = Double(frame) / Double(frames)
                self.camera = start.interpolated(to: target, t: t * t * (3 - 2 * t))
            }
        }
    }

    /// Zooms to an element, with its centre at `anchor` from the middle of the view.
    func focus(on element: GraphElementRef, anchor: CGSize, in size: CGSize) {
        guard let document, let position = GraphHitTest.position(of: element, document: document, positions: positions) else { return }
        let zoom: Double
        switch element {
        case .node: zoom = max(camera.zoom, 2.2)
        case .edge: zoom = max(camera.zoom, 1.6)
        }
        animateCamera(to: camera.focused(on: position, zoom: zoom, anchor: anchor, in: size))
    }

    /// Where an element is drawn with the camera as it will be after `focus`.
    func screenPoint(of element: GraphElementRef, in size: CGSize) -> CGPoint? {
        guard let document, let position = GraphHitTest.position(of: element, document: document, positions: positions) else { return nil }
        return camera.project(position, in: size).point
    }

    func resetCamera() { animateCamera(to: GraphCamera(mode: mode)) }

    // MARK: Lookups

    func node(_ id: String) -> GraphNode? { document?.nodes.first { $0.id == id } }
    func edge(_ id: String) -> GraphEdge? { document?.edges.first { $0.id == id } }
}
