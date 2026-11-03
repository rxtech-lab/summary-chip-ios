import SummaryKit
import SwiftUI

/// A graph: drawn in 3D or on a plane, with queries, an agent, and each element's info in a
/// popover on wide layouts and a half sheet on iPhone.
struct GraphDetailView: View {
    let environment: AppEnvironment
    let graphID: String
    let title: String
    @State private var model: GraphModel
    @State private var versions: DocumentVersionsModel
    @State private var chat: ChatModel
    @State private var sheet: GraphSheet?
    @State private var popover: GraphElementRef?
    @State private var showsCompactInspector = false
    @State private var popoverTask: Task<Void, Never>?
    @State private var canvasSize = CGSize.zero
    @State private var tapFeedback = 0
    @State private var summary: Summary?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(environment: AppEnvironment, graphID: String, title: String = "") {
        self.environment = environment
        self.graphID = graphID
        self.title = title
        _model = State(initialValue: GraphModel(id: graphID, api: environment.api))
        _versions = State(initialValue: DocumentVersionsModel(api: environment.api, id: graphID))
        _chat = State(initialValue: ChatModel(client: environment.chatClient, store: environment.chatStore, graph: GraphChat(id: graphID)))
    }

    /// iPhone gets a half sheet; macOS, iPad and a wide iPhone (Pro Max, foldable) get a popover.
    private var usesPopover: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    var body: some View {
        content
            .navigationTitle(model.document?.title ?? title)
            .summaryInlineNavigationTitle()
            .toolbar { toolbar }
            .task { await initialLoad() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
            .overlay(alignment: .top) { noticeOverlay }
            .overlay { if let status = model.status, sheet == nil { ActionStatusOverlay(status) } }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .animation(.spring(duration: 0.35), value: model.notice)
            .animation(.spring(duration: 0.35), value: model.selection)
            .sensoryFeedback(.selection, trigger: tapFeedback)
            .sensoryFeedback(.selection, trigger: model.mode)
            .sensoryFeedback(.success, trigger: model.savedCount)
            .sensoryFeedback(.impact(weight: .light), trigger: model.selection)
            .statusAlert("Couldn't Save", message: model.actionError) { model.actionError = nil }
            .sheet(item: $sheet, onDismiss: { Task { await model.refresh() } }) { sheet in sheetContent(sheet) }
            .sheet(isPresented: $showsCompactInspector, onDismiss: { if !usesPopover { model.inspected = nil } }) { compactInspector }
            .documentVersions(versions) { restored in
                guard restored.graph != nil else { return }
                Task {
                    await model.refresh()
                    if let item = try? await environment.api.summary(id: graphID) { environment.library.upsert(item) }
                }
            }
            .onChange(of: versions.preview) { _, preview in
                if case .graph(let document) = preview?.content { model.preview(document) } else { model.preview(nil) }
            }
            .onChange(of: model.graph?.revision) { old, new in
                guard model.isOwner, old != nil, old != new else { return }
                Task { await versions.reload() }
                Task { if let item = try? await environment.api.summary(id: graphID) { environment.library.upsert(item) } }
            }
            .onChange(of: model.inspected) { _, inspected in
                if inspected == nil {
                    popover = nil
                    showsCompactInspector = false
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let document = model.document {
            ZStack {
                GraphCanvasView(model: model, document: document) { element, size in
                    canvasSize = size
                    tap(element, size: size)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                .popover(item: popoverBinding, attachmentAnchor: .rect(.rect(popoverAnchor)), arrowEdge: .top) { element in
                    popoverContent(element)
                }
                if document.nodes.isEmpty { emptyState }
                else if !model.isLaidOut { ProgressView("Arranging the graph…") }
                viewModePicker
                cameraControls
            }
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Graph Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        } else {
            ProgressView("Loading graph…").accessibilityIdentifier("graph-loading")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Nodes Yet", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Add a node, or ask the graph agent to build the graph.")
        } actions: {
            if model.canEdit {
                Button("Add Node") { sheet = .newNode }
                Button("Ask the Agent") { sheet = .agent }
            }
        }
    }

    /// Floats over the graph so the bar keeps the graph's title.
    private var viewModePicker: some View {
        Picker("View", selection: $model.mode) {
            Text(verbatim: "3D").tag(GraphViewMode.globe)
            Text(verbatim: "2D").tag(GraphViewMode.plane)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityIdentifier("graph-view-mode")
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var cameraControls: some View {
        VStack(spacing: 0) {
            cameraButton("Zoom In", systemImage: "plus", identifier: "graph-zoom-in") { model.animateCamera(to: model.camera.zoomed(by: 1.5), duration: 0.2) }
            Divider().frame(width: 28)
            cameraButton("Zoom Out", systemImage: "minus", identifier: "graph-zoom-out") { model.animateCamera(to: model.camera.zoomed(by: 1 / 1.5), duration: 0.2) }
            Divider().frame(width: 28)
            cameraButton("Reset View", systemImage: "arrow.counterclockwise", identifier: "graph-reset-view") { model.resetCamera() }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func cameraButton(_ title: LocalizedStringKey, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.canEdit {
                Menu {
                    Button("Add Node", systemImage: "circle.badge.plus") { sheet = .newNode }
                        .accessibilityIdentifier("graph-add-node")
                    Button("Add Edge", systemImage: "arrow.triangle.branch") { sheet = .newEdge(source: nil) }
                        .disabled((model.document?.nodes.count ?? 0) < 1)
                        .accessibilityIdentifier("graph-add-edge")
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("graph-add")
            }
            Button("Query", systemImage: "line.3.horizontal.decrease.circle") { sheet = .query }
                .disabled(versions.isPreviewing)
                .accessibilityIdentifier("graph-query")
            Menu {
                if model.isOwner {
                    Button("Graph Agent", systemImage: "sparkles") { sheet = .agent }
                        .accessibilityIdentifier("graph-agent")
                }
                Button("Elements", systemImage: "list.bullet") { sheet = .elements }
                    .accessibilityIdentifier("graph-elements")
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                if model.isOwner {
                    Section {
                        VersionToolbarMenu(model: versions)
                        if model.canEdit, let document = model.document {
                            Button("Graph Details", systemImage: "pencil") { sheet = .meta(document) }
                        }
                    }
                    Section {
                        Button("Delete Graph", systemImage: "trash", role: .destructive) {
                            Task {
                                summary = try? await environment.api.summary(id: graphID)
                                if summary != nil { sheet = .delete }
                            }
                        }
                        .accessibilityIdentifier("graph-delete")
                    }
                }
                if let url = model.graph?.shareUrl, model.graph?.visibility == .public {
                    Section { ShareLink("Share", item: url) }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("graph-more")
        }
    }

    @ViewBuilder
    private var noticeOverlay: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("graph-notice")
        }
    }

    /// The bar saying what's picked out, or that an old version is showing.
    @ViewBuilder
    private var bottomBar: some View {
        if versions.isPreviewing {
            VersionPreviewBanner(model: versions)
        } else if let selection = model.selection {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selection.nodeIds.count) nodes, \(selection.edgeIds.count) edges")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("graph-selection-count")
                    if let query = selection.query {
                        Text(query).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Picker("Show", selection: Binding(get: { selection.mode }, set: { model.setSelectionMode($0) })) {
                    Text("Highlight").tag(GraphSelectionMode.highlight)
                    Text("Only").tag(GraphSelectionMode.isolate)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("graph-selection-mode")
                Button("Clear", systemImage: "xmark.circle.fill") { model.select(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("graph-selection-clear")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: 620)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Info

    /// A tap zooms to the element and opens its info; a tap on nothing closes it.
    private func tap(_ element: GraphElementRef?, size: CGSize) {
        popoverTask?.cancel()
        guard let element else {
            model.inspected = nil
            return
        }
        tapFeedback += 1
        open(element, size: size)
    }

    private func open(_ element: GraphElementRef, size: CGSize) {
        model.inspected = element
        if usesPopover {
            popover = nil
            model.focus(on: element, anchor: .zero, in: size)
            // Anchored once the camera settles, so it points at where the element ends up.
            popoverTask = Task {
                try? await Task.sleep(for: .milliseconds(460))
                guard !Task.isCancelled, model.inspected == element else { return }
                popover = element
            }
        } else {
            // The half sheet covers the lower half; keep the element in the part still showing.
            model.focus(on: element, anchor: CGSize(width: 0, height: -size.height * 0.25), in: size)
            showsCompactInspector = true
        }
    }

    /// Only the system dismissing the popover (a tap outside) writes here: the element is done with.
    private var popoverBinding: Binding<GraphElementRef?> {
        Binding(get: { popover }, set: { next in
            let closing = popover
            popover = next
            if next == nil, let closing, model.inspected == closing { model.inspected = nil }
        })
    }

    private var popoverAnchor: CGRect {
        guard let element = popover ?? model.inspected, let point = model.screenPoint(of: element, in: canvasSize) else {
            return CGRect(x: canvasSize.width / 2, y: canvasSize.height / 2, width: 1, height: 1)
        }
        return CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
    }

    private func popoverContent(_ element: GraphElementRef) -> some View {
        NavigationStack {
            ScrollView {
                GraphInspectorContent(model: model, element: element) { open($0, size: canvasSize) }
                    .padding()
            }
            .toolbar { inspectorToolbar(element) }
            .navigationTitle(element.kindTitle)
            .summaryInlineNavigationTitle()
        }
        .frame(idealWidth: 360, minHeight: 280, idealHeight: 460)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private var compactInspector: some View {
        NavigationStack {
            ScrollView {
                if let element = model.inspected {
                    GraphInspectorContent(model: model, element: element) { open($0, size: canvasSize) }
                        .padding()
                }
            }
            .navigationTitle(model.inspected?.kindTitle ?? "")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { model.inspected = nil }
                        .accessibilityIdentifier("graph-inspector-close")
                }
                if let element = model.inspected { inspectorToolbar(element) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
    }

    @ToolbarContentBuilder
    private func inspectorToolbar(_ element: GraphElementRef) -> some ToolbarContent {
        if model.canEdit {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Edit", systemImage: "pencil") { present(element.editSheet) }
                        .accessibilityIdentifier("graph-inspector-edit")
                    if case .node(let id) = element {
                        Button("Add Edge From Here", systemImage: "arrow.triangle.branch") { present(.newEdge(source: id)) }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("graph-inspector-actions")
            }
        }
    }

    /// Closes the info first: only one thing can present at a time.
    private func present(_ next: GraphSheet) {
        popover = nil
        showsCompactInspector = false
        model.inspected = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            sheet = next
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: GraphSheet) -> some View {
        switch sheet {
        case .newNode: GraphNodeEditorSheet(model: model, node: nil)
        case .editNode(let id): GraphNodeEditorSheet(model: model, node: model.node(id))
        case .newEdge(let source): GraphEdgeEditorSheet(model: model, edge: nil, source: source)
        case .editEdge(let id): GraphEdgeEditorSheet(model: model, edge: model.edge(id))
        case .meta(let document): GraphMetaSheet(model: model, document: document)
        case .elements:
            GraphElementsSheet(model: model) { element in
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    open(element, size: canvasSize)
                }
            }
        case .query:
            GraphQuerySheet(model: model) { request in
                chat.draft = request
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    self.sheet = .agent
                }
            }
        case .agent:
            ChatView(
                environment: environment,
                model: chat,
                onGraphUpdated: { [model] in Task { await model.refresh() } },
                onGraphSelection: { [model] selection in model.apply(selection: selection) }
            )
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        case .delete:
            if let summary {
                DeleteSummarySheet(api: environment.api, summary: summary) {
                    environment.library.remove(id: summary.id)
                    dismiss()
                }
            }
        }
    }

    private func initialLoad() async {
        await model.load()
        if model.isOwner { await versions.reload() }
    }
}

enum GraphSheet: Identifiable, Hashable {
    case newNode
    case editNode(String)
    case newEdge(source: String?)
    case editEdge(String)
    case meta(GraphDocument)
    case elements
    case query
    case agent
    case delete

    var id: String {
        switch self {
        case .newNode: "new-node"
        case .editNode(let id): "node-\(id)"
        case .newEdge(let source): "new-edge-\(source ?? "")"
        case .editEdge(let id): "edge-\(id)"
        case .meta: "meta"
        case .elements: "elements"
        case .query: "query"
        case .agent: "agent"
        case .delete: "delete"
        }
    }
}

private extension GraphElementRef {
    var kindTitle: String {
        switch self {
        case .node: String(localized: "Node")
        case .edge: String(localized: "Edge")
        }
    }

    var editSheet: GraphSheet {
        switch self {
        case .node(let id): .editNode(id)
        case .edge(let id): .editEdge(id)
        }
    }
}
