import PhotosUI
import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// `New Graph`: a name, then the graph agent or the Add menu fills it in.
struct NewGraphSheet: View {
    let api: SummaryAPIClient
    let onCreated: (Graph) -> Void
    @State private var title = ""
    @State private var details = ""
    @State private var isCreating = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $title).accessibilityIdentifier("new-graph-name")
                    TextField("Description", text: $details, axis: .vertical).lineLimit(2...5)
                } footer: {
                    Text("Add nodes and edges yourself, or ask the graph agent to build it for you.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Graph")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isCreating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("new-graph-create")
                }
            }
            .overlay { if isCreating { ActionStatusOverlay(String(localized: "Creating graph…")) } }
            .statusAlert("Couldn't Create Graph", message: error) { error = nil }
            .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        }
        .interactiveDismissDisabled(isCreating)
        .summarySheetSize()
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        do {
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            let graph = try await api.createGraph(GraphDocument(title: title.trimmingCharacters(in: .whitespacesAndNewlines), description: trimmed.isEmpty ? nil : trimmed))
            onCreated(graph)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The name and description.
struct GraphMetaSheet: View {
    let model: GraphModel
    @State private var title: String
    @State private var details: String
    @Environment(\.dismiss) private var dismiss

    init(model: GraphModel, document: GraphDocument) {
        self.model = model
        _title = State(initialValue: document.title)
        _details = State(initialValue: document.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $title)
                TextField("Description", text: $details, axis: .vertical).lineLimit(2...8)
            }
            .formStyle(.grouped)
            .navigationTitle("Graph Details")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await model.apply([.setMeta(title: title.trimmingCharacters(in: .whitespacesAndNewlines), description: trimmed.isEmpty ? nil : trimmed)], status: String(localized: "Saving…")) { dismiss() }
                        }
                    }
                    .disabled(model.status != nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if let status = model.status { ActionStatusOverlay(status) } }
        }
        .interactiveDismissDisabled(model.status != nil)
        .summarySheetSize()
    }
}

/// What both editors share: pictures and the JSON behind the element.
private struct GraphElementDataSections: View {
    let graphID: String
    let api: SummaryAPIClient
    @Binding var images: [GraphImage]
    @Binding var propertiesText: String
    @Binding var viewText: String
    @Binding var isUploading: Bool
    @Binding var error: String?
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Section("Images") {
            ForEach($images) { $image in
                HStack(spacing: 12) {
                    AsyncImage(url: image.url) { phase in
                        if let picture = phase.image { picture.resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                    TextField("Caption", text: Binding(get: { image.caption ?? "" }, set: { image.caption = $0.isEmpty ? nil : $0 }))
                    Button("Remove Image", systemImage: "minus.circle", role: .destructive) { images.removeAll { $0.id == image.id } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                Label("Add Images", systemImage: "photo.badge.plus")
            }
            .accessibilityIdentifier("graph-add-images")
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await upload(items) }
        }
        Section {
            TextEditor(text: $propertiesText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Properties JSON"))
                .accessibilityIdentifier("graph-properties-editor")
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Properties (JSON)")
        } footer: {
            Text("Any JSON object. Queries read it as n.name or n.address.city.")
        }
        Section {
            TextEditor(text: $viewText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Custom view JSON"))
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Custom View (JSON)")
        } footer: {
            Text("Optional. A view with {root, elements}, drawn natively above the properties. The graph agent can write one for you.")
        }
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        isUploading = true
        defer {
            isUploading = false
            picked = []
        }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
                let url = try await api.uploadGraphImage(
                    id: graphID,
                    data: data,
                    filename: "image.\(type.preferredFilenameExtension ?? "jpg")",
                    mimeType: type.preferredMIMEType ?? "image/jpeg"
                )
                images.append(GraphImage(url: url))
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
    }
}

private func parsedView(_ text: String) throws -> TripViewSpec? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    return try JSONDecoder().decode(TripViewSpec.self, from: Data(trimmed.utf8))
}

private func viewSource(_ view: TripViewSpec?) -> String {
    guard let view else { return "" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(view)).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

/// Adds or changes a node. Deleting lives here too, behind a native confirmation.
struct GraphNodeEditorSheet: View {
    let model: GraphModel
    private let existing: GraphNode?
    @State private var label: String
    @State private var types: String
    @State private var usesColor: Bool
    @State private var color: Color
    @State private var images: [GraphImage]
    @State private var propertiesText: String
    @State private var viewText: String
    @State private var isUploading = false
    @State private var confirmsDelete = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: GraphModel, node: GraphNode?) {
        self.model = model
        existing = node
        _label = State(initialValue: node?.label ?? "")
        _types = State(initialValue: node?.types.joined(separator: ", ") ?? "")
        _usesColor = State(initialValue: node?.color != nil)
        _color = State(initialValue: Color(graphHex: node?.color) ?? .blue)
        _images = State(initialValue: node?.images ?? [])
        _propertiesText = State(initialValue: node.map { $0.properties.isEmpty ? "" : GraphJSON.pretty(.object($0.properties)) } ?? "")
        _viewText = State(initialValue: viewSource(node?.view))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label).accessibilityIdentifier("graph-node-label")
                    TextField("Types, comma separated", text: $types).autocorrectionDisabled().accessibilityIdentifier("graph-node-types")
                    Toggle("Custom Color", isOn: $usesColor)
                    if usesColor { ColorPicker("Color", selection: $color, supportsOpacity: false) }
                } footer: {
                    Text("Types are what a query matches, as in (n:Person).")
                }
                GraphElementDataSections(graphID: model.id, api: model.api, images: $images, propertiesText: $propertiesText, viewText: $viewText, isUploading: $isUploading, error: $error)
                if existing != nil {
                    Section {
                        Button("Delete Node", role: .destructive) { confirmsDelete = true }
                            .accessibilityIdentifier("graph-node-delete")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "New Node" : "Edit Node")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isBusy || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("graph-node-save")
                }
            }
            .overlay {
                if isUploading { ActionStatusOverlay(String(localized: "Uploading…")) }
                else if let status = model.status { ActionStatusOverlay(status) }
            }
            .confirmationDialog("Delete this node?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Node", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its edges are removed with it.")
            }
            .statusAlert("Couldn't Save", message: error) { error = nil }
            .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        }
        .interactiveDismissDisabled(isBusy)
        .summarySheetSize()
    }

    private var isBusy: Bool { isUploading || model.status != nil }

    private func save() async {
        do {
            let properties = try GraphJSON.parseObject(propertiesText)
            let view = try parsedView(viewText)
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = existing?.id ?? GraphElementID.make(from: trimmed, taken: Set(model.document?.nodes.map(\.id) ?? []))
            let node = GraphNode(
                id: id,
                label: trimmed,
                types: types.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                color: usesColor ? color.graphHex : nil,
                properties: properties,
                images: images,
                view: view
            )
            if await model.apply([.upsertNode(node)], status: String(localized: "Saving…"), done: String(localized: "Node saved")) { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let existing else { return }
        if await model.apply([.deleteNode(existing.id)], status: String(localized: "Deleting…"), done: String(localized: "Node deleted")) { dismiss() }
    }
}

/// Adds or changes an edge.
struct GraphEdgeEditorSheet: View {
    let model: GraphModel
    private let existing: GraphEdge?
    @State private var label: String
    @State private var source: String
    @State private var target: String
    @State private var directed: Bool
    @State private var images: [GraphImage]
    @State private var propertiesText: String
    @State private var viewText: String
    @State private var isUploading = false
    @State private var confirmsDelete = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: GraphModel, edge: GraphEdge?, source: String? = nil) {
        self.model = model
        existing = edge
        let nodes = model.document?.nodes ?? []
        let from = edge?.source ?? source ?? nodes.first?.id ?? ""
        _label = State(initialValue: edge?.label ?? "")
        _source = State(initialValue: from)
        _target = State(initialValue: edge?.target ?? nodes.first { $0.id != from }?.id ?? from)
        _directed = State(initialValue: edge?.directed ?? true)
        _images = State(initialValue: edge?.images ?? [])
        _propertiesText = State(initialValue: edge.map { $0.properties.isEmpty ? "" : GraphJSON.pretty(.object($0.properties)) } ?? "")
        _viewText = State(initialValue: viewSource(edge?.view))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label).autocorrectionDisabled().accessibilityIdentifier("graph-edge-label")
                    nodePicker("From", selection: $source).accessibilityIdentifier("graph-edge-source")
                    nodePicker("To", selection: $target).accessibilityIdentifier("graph-edge-target")
                    Toggle("Has a Direction", isOn: $directed)
                } footer: {
                    Text("The label is what a query matches, as in -[r:KNOWS]->.")
                }
                GraphElementDataSections(graphID: model.id, api: model.api, images: $images, propertiesText: $propertiesText, viewText: $viewText, isUploading: $isUploading, error: $error)
                if existing != nil {
                    Section {
                        Button("Delete Edge", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "New Edge" : "Edit Edge")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isBusy || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.isEmpty || target.isEmpty)
                        .accessibilityIdentifier("graph-edge-save")
                }
            }
            .overlay {
                if isUploading { ActionStatusOverlay(String(localized: "Uploading…")) }
                else if let status = model.status { ActionStatusOverlay(status) }
            }
            .confirmationDialog("Delete this edge?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Edge", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            }
            .statusAlert("Couldn't Save", message: error) { error = nil }
            .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        }
        .interactiveDismissDisabled(isBusy)
        .summarySheetSize()
    }

    private var isBusy: Bool { isUploading || model.status != nil }

    private func nodePicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(model.document?.nodes ?? []) { node in
                Text(node.label).tag(node.id)
            }
        }
    }

    private func save() async {
        do {
            let properties = try GraphJSON.parseObject(propertiesText)
            let view = try parsedView(viewText)
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = existing?.id ?? GraphElementID.make(from: "\(source)-\(trimmed)-\(target)", taken: Set(model.document?.edges.map(\.id) ?? []))
            let edge = GraphEdge(id: id, source: source, target: target, label: trimmed, directed: directed, color: existing?.color, properties: properties, images: images, view: view)
            if await model.apply([.upsertEdge(edge)], status: String(localized: "Saving…"), done: String(localized: "Edge saved")) { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let existing else { return }
        if await model.apply([.deleteEdge(existing.id)], status: String(localized: "Deleting…"), done: String(localized: "Edge deleted")) { dismiss() }
    }
}

extension Color {
    /// `#RRGGBB`, as the document stores it.
    var graphHex: String? {
        #if os(macOS)
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let (red, green, blue) = (color.redComponent, color.greenComponent, color.blueComponent)
        #else
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
