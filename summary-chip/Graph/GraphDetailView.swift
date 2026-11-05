import SummaryKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A graph: drawn in 3D or on a plane, with queries, an agent, and each element's info in a
/// popover on wide layouts and a half sheet on iPhone.
struct GraphDetailView: View {
    let environment: AppEnvironment
    let graphID: String
    let title: String
    var spatialPanel: String? = nil
    @State private var model: GraphModel
    @State private var versions: DocumentVersionsModel
    @State private var chat: ChatModel
    @Environment(\.openSideAgent) private var openSideAgent
    @Environment(\.setSideAgentContext) private var setSideAgentContext
    @State private var sheet: GraphSheet?
    @State private var generatedUI: ChatRenderedUI?
    @State private var popover: GraphElementRef?
    @State private var showsCompactInspector = false
    @State private var popoverTask: Task<Void, Never>?
    @State private var canvasSize = CGSize.zero
    @State private var tapFeedback = 0
    @State private var queryExpanded = false
    @State private var summary: Summary?
    @State private var isLoadingShare = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS) || os(visionOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(environment: AppEnvironment, graphID: String, title: String = "", sharedModel: GraphModel? = nil, spatialPanel: String? = nil) {
        self.spatialPanel = spatialPanel
        self.environment = environment
        self.graphID = graphID
        self.title = title
        _model = State(initialValue: sharedModel ?? GraphModel(id: graphID, api: environment.api))
        _versions = State(initialValue: DocumentVersionsModel(api: environment.api, id: graphID))
        _chat = State(initialValue: ChatModel(client: environment.chatClient, store: environment.chatStore, graph: GraphChat(id: graphID)))
    }

    /// iPhone gets a half sheet; macOS, iPad and a wide iPhone (Pro Max, foldable) get a popover.
    private var usesPopover: Bool {
        #if os(iOS) || os(visionOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    var body: some View {
        content
            .navigationTitle(model.document?.title ?? title)
            .summaryInlineNavigationTitle()
            .toolbar { if spatialPanel == nil { toolbar } }
            .task(id: graphID) {
                await initialLoad()
                guard !Task.isCancelled, model.isOwner else { return }
                configureAgent()
                setSideAgentContext?(chat)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
            .overlay(alignment: .top) { noticeOverlay }
            .overlay { if isLoadingShare { ActionStatusOverlay("Loading…") } }
            .overlay { if let status = model.status, sheet == nil { ActionStatusOverlay(status) } }
            .safeAreaInset(edge: .bottom) {
                if versions.isPreviewing { VersionPreviewBanner(model: versions) }
            }
            .animation(.spring(duration: 0.35), value: model.notice)
            .animation(.spring(duration: 0.35), value: model.selection)
            .sensoryFeedback(.selection, trigger: tapFeedback)
            .sensoryFeedback(.selection, trigger: model.mode)
            .sensoryFeedback(.success, trigger: model.savedCount)
            .sensoryFeedback(.impact(weight: .light), trigger: model.selection)
            .statusAlert("Couldn't Save", message: model.actionError) { model.actionError = nil }
            .sheet(item: $sheet, onDismiss: { Task { await model.refresh() } }) { sheet in sheetContent(sheet) }
            .sheet(isPresented: $showsCompactInspector, onDismiss: { model.inspected = nil }) { compactInspector }
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
            if spatialPanel == "controls" {
                VStack(spacing: 12) {
                    Text(model.document?.title ?? title)
                        .font(.headline).lineLimit(2)
                    queryBar
                    HStack(alignment: .top, spacing: 12) {
                        GraphLegend(nodes: document.nodes)
                        viewModePicker
                        cameraButtons
                    }
                    HStack(spacing: 12) { toolbarActions }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            } else {
            ZStack {
                GraphCanvasView(model: model, document: document, selectedElements: chat.graphElements, onSelect: { element, additive in
                    chat.graphDocument = document
                    guard let element else {
                        chat.graphElements = []
                        return
                    }
                    if additive {
                        if chat.graphElements.contains(element) { chat.graphElements.removeAll { $0 == element } }
                        else { chat.graphElements.append(element) }
                    } else {
                        chat.graphElements = [element]
                    }
                }) { element, size in
                    canvasSize = size
                    tap(element, size: size)
                }
                .onChange(of: document, initial: true) { _, updated in
                    chat.graphDocument = updated
                    chat.graphElements.removeAll { element in
                        switch element {
                        case .node(let id): return !updated.nodes.contains { $0.id == id }
                        case .edge(let id): return !updated.edges.contains { $0.id == id }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: chat.graphElements)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                .popover(item: popoverBinding, attachmentAnchor: .rect(.rect(popoverAnchor)), arrowEdge: .bottom) { element in
                    if let ui = generatedUI, element == .node(ui.nodeId ?? "") {
                        ChatGeneratedUIPopover(ui: ui)
                    } else {
                        popoverContent(element)
                    }
                }
                if document.nodes.isEmpty { emptyState }
                else if !model.isLaidOut { ProgressView("Arranging the graph…") }
                if spatialPanel == nil {
                VStack(alignment: .leading, spacing: 12) {
                    queryBar
                    if !document.nodes.isEmpty {
                        GraphLegend(nodes: document.nodes)
                    }
                    viewModePicker
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                cameraControls
                }
            }
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
                Button("Ask the Agent") { showAgent() }
            }
        }
    }

    /// Floats over the graph so the bar keeps the graph's title.
    private var viewModePicker: some View {
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

    private var cameraControls: some View {
        cameraButtons
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var cameraButtons: some View {
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
            tapFeedback += 1
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

// Graph actions, inspectors and editing workflows.
private extension GraphDetailView {
    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .summaryTrailing) { toolbarActions }
    }

    @ViewBuilder
    var toolbarActions: some View {
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
            if model.isOwner {
                AgentChatToggle { showAgent() }
                    .accessibilityIdentifier("graph-agent")
            }
            Menu {
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
                if model.graph != nil {
                    Section {
                        Button("Share…", systemImage: "square.and.arrow.up") {
                            tapFeedback += 1
                            Task {
                                isLoadingShare = true
                                defer { isLoadingShare = false }
                                do {
                                    summary = try await environment.api.summary(id: graphID)
                                    sheet = .share
                                } catch {
                                    model.actionError = error.localizedDescription
                                }
                            }
                        }
                        .disabled(isLoadingShare)
                        .accessibilityIdentifier("graph-share")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("graph-more")
    }

    @ViewBuilder
    private var noticeOverlay: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .platformGlassEffect(.regular, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("graph-notice")
        }
    }

    /// Floats the query selection controls over the graph without shrinking the canvas.
    @ViewBuilder
    private var queryBar: some View {
        if !versions.isPreviewing, let selection = model.selection {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    tapFeedback += 1
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
                            tapFeedback += 1
                            sheet = .query
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
                            tapFeedback += 1
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
                        tapFeedback += 1
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

    // MARK: Info

    /// A tap zooms to the element and opens its info; a tap on nothing closes it.
    private func tap(_ element: GraphElementRef?, size: CGSize) {
        popoverTask?.cancel()
        guard let element else {
            model.inspected = nil
            return
        }
        #if os(visionOS)
        if case .node(let nodeID) = element {
            popover = nil
            showsCompactInspector = false
            tapFeedback += 1
            openWindow(id: "graph-node", value: SpatialGraphNodeID(graphID: graphID, nodeID: nodeID))
            return
        }
        #endif
        open(element, size: size)
    }

    private func open(_ element: GraphElementRef, size: CGSize) {
        tapFeedback += 1
        model.inspected = element
        if usesPopover && !showsCompactInspector {
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
            if next == nil { generatedUI = nil }
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
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Open in Window", systemImage: "arrow.up.forward.square") {
                    GraphInspectorWindow.show(model: model, element: element, environment: environment)
                }
                .accessibilityIdentifier("graph-inspector-open-window")
                Spacer()
                if model.canEdit {
                    Menu {
                        Button("Edit", systemImage: "pencil") { present(element.editSheet) }
                            .accessibilityIdentifier("graph-inspector-edit")
                        if case .node(let id) = element {
                            Button("Add Edge From Here", systemImage: "arrow.triangle.branch") { present(.newEdge(source: id)) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Actions")
                    .accessibilityIdentifier("graph-inspector-actions")
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                GraphInspectorContent(model: model, element: element) { open($0, size: canvasSize) }
                    .padding()
            }
        }
        .frame(width: 520, height: 600)
        #else
        NavigationStack {
            ScrollView {
                GraphInspectorContent(model: model, element: element) { open($0, size: canvasSize) }
                    .padding()
            }
            .toolbar { inspectorToolbar(element, allowsSheet: true) }
            .navigationTitle(element.kindTitle)
            .summaryInlineNavigationTitle()
        }
        .frame(width: 360, height: 400)
        .presentationCompactAdaptation(.popover)
        #endif
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
    private func inspectorToolbar(_ element: GraphElementRef, allowsSheet: Bool = false) -> some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .summaryTrailing) {
            Button("Open in Window", systemImage: "arrow.up.forward.square") {
                GraphInspectorWindow.show(model: model, element: element, environment: environment)
            }
            .help("Open details in a separate window")
            .accessibilityIdentifier("graph-inspector-open-window")
        }
        #endif
        if model.canEdit || (allowsSheet && canOpenInspectorSheet) {
            ToolbarItem(placement: .summaryTrailing) {
                Menu {
                    if allowsSheet && canOpenInspectorSheet {
                        Button("Open in Sheet", systemImage: "arrow.up.left.and.arrow.down.right") {
                            openInspectorSheet(element)
                        }
                        .accessibilityIdentifier("graph-inspector-open-sheet")
                    }
                    if model.canEdit {
                        Button("Edit", systemImage: "pencil") { present(element.editSheet) }
                            .accessibilityIdentifier("graph-inspector-edit")
                        if case .node(let id) = element {
                            Button("Add Edge From Here", systemImage: "arrow.triangle.branch") { present(.newEdge(source: id)) }
                        }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("graph-inspector-actions")
            }
        }
    }

    private var canOpenInspectorSheet: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private func openInspectorSheet(_ element: GraphElementRef) {
        tapFeedback += 1
        popoverTask?.cancel()
        popover = nil
        popoverTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, model.inspected == element else { return }
            showsCompactInspector = true
            model.focus(on: element, anchor: CGSize(width: 0, height: -canvasSize.height * 0.25), in: canvasSize)
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

    private func showAgent() {
        #if os(visionOS)
        sheet = .agent
        #else
        if let openSideAgent {
            configureAgent()
            openSideAgent(chat)
        } else {
            sheet = .agent
        }
        #endif
    }

    private func configureAgent() {
        chat.onGraphOpenNode = { id, presentation in
            guard model.document?.nodes.contains(where: { $0.id == id }) == true else { return false }
            let element = GraphElementRef.node(id)
            #if os(macOS)
            if presentation == "window" {
                GraphInspectorWindow.show(model: model, element: element, environment: environment)
                tapFeedback += 1
                return true
            }
            #endif
            guard presentation == "popover", canvasSize.width > 0, canvasSize.height > 0,
                  model.positions[id] != nil, model.visibility.shows(node: id) else { return false }
            popoverTask?.cancel()
            generatedUI = nil
            model.autoRotate = false
            open(element, size: canvasSize)
            return true
        }
        chat.onGraphCenter = { ids in
            guard canvasSize.width > 0, canvasSize.height > 0,
                  ids.allSatisfy({ model.positions[$0] != nil && model.visibility.shows(node: $0) }) else { return false }
            let target = model.camera.centered(on: ids.compactMap { model.positions[$0] }, in: canvasSize)
            model.autoRotate = false
            model.animateCamera(to: target)
            tapFeedback += 1
            return true
        }
        chat.onGraphUI = { ui in
            guard let id = ui.nodeId, model.document?.nodes.contains(where: { $0.id == id }) == true else { return }
            generatedUI = ui
            popover = .node(id)
            tapFeedback += 1
        }
        chat.onGraphUpdated = { [model] in Task { await model.refresh() } }
        chat.onGraphSelection = { [model] selection in model.apply(selection: selection) }
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
                    showAgent()
                }
            }
        case .agent:
            #if os(visionOS)
            SpatialVoiceView(environment: environment, graph: GraphChat(id: graphID),
                             onUpdated: { [model] in Task { await model.refresh() } })
            #else
            ChatView(
                environment: environment,
                model: chat,
                onGraphUpdated: { [model] in Task { await model.refresh() } },
                onGraphSelection: { [model] selection in model.apply(selection: selection) }
            )
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            #endif
        case .share:
            if let summary {
                ShareModeSheet(summary: summary, api: environment.api) { updated in
                    self.summary = updated
                    environment.library.upsert(updated)
                    Task { await model.refresh() }
                }
            }
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
    case share

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
        case .share: "share"
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


#if os(macOS)
/// Retains one reusable agent window for this graph detail's lifetime.
@MainActor
private final class GraphAgentWindow {
    private var window: NSWindow?

    func show(_ content: some View) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Graph Agent")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 420)
        window.contentViewController = NSHostingController(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
#endif
