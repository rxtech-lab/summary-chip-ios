import SummaryKit
import SwiftUI

/// Write a query, run it and light up the result, keep it for later, or hand the writing to the agent.
struct GraphQuerySheet: View {
    let model: GraphModel
    let onAskAgent: (String) -> Void
    @State private var text: String
    @State private var mode: GraphSelectionMode
    @State private var isRunning = false
    @State private var result: GraphQueryResult?
    @State private var error: String?
    @State private var savingAs: PendingSave?
    @State private var deleting: GraphSavedQuery?
    @Environment(\.dismiss) private var dismiss

    private struct PendingSave: Identifiable {
        let id = UUID()
        var query: String
    }

    init(model: GraphModel, onAskAgent: @escaping (String) -> Void) {
        self.model = model
        self.onAskAgent = onAskAgent
        _text = State(initialValue: model.selection?.query ?? "")
        _mode = State(initialValue: model.selection?.mode ?? .highlight)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var saved: [GraphSavedQuery] { model.document?.queries ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                editor
                if !saved.isEmpty { savedQueries }
                examples
            }
            .formStyle(.grouped)
            .navigationTitle("Query")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { Task { await run(trimmed) } }
                        .disabled(isRunning || trimmed.isEmpty)
                        .accessibilityIdentifier("graph-query-run")
                }
            }
            .overlay {
                if isRunning { ActionStatusOverlay(String(localized: "Running query…")) }
                else if let status = model.status { ActionStatusOverlay(status) }
            }
            .statusAlert("Couldn't Run Query", message: error) { error = nil }
            .sheet(item: $savingAs) { pending in
                GraphSaveQuerySheet(model: model, query: pending.query)
            }
            .confirmationDialog("Delete this query?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { query in
                Button("Delete Query", role: .destructive) {
                    Task { await model.apply([.deleteQuery(query.id)], status: String(localized: "Deleting…"), done: String(localized: "Query deleted")) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { query in
                Text(query.name)
            }
            .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
            .sensoryFeedback(.success, trigger: result) { _, new in new.map { !$0.nodeIds.isEmpty || !$0.edgeIds.isEmpty } ?? false }
        }
        .summarySheetSize()
    }

    private var editor: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Query"))
                .accessibilityIdentifier("graph-query-editor")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Picker("Show Results", selection: $mode) {
                Text("Highlight").tag(GraphSelectionMode.highlight)
                Text("Show Only").tag(GraphSelectionMode.isolate)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("graph-query-mode")
            if let result, result.nodeIds.isEmpty, result.edgeIds.isEmpty {
                Label("Nothing matched", systemImage: "circle.slash").foregroundStyle(.secondary).accessibilityIdentifier("graph-query-empty")
            }
            if model.canEdit {
                Button("Save Query", systemImage: "bookmark") { savingAs = PendingSave(query: trimmed) }
                    .disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("graph-query-save")
            }
            if model.isOwner {
                Button("Ask Agent to Write It", systemImage: "sparkles") {
                    let request = trimmed.isEmpty ? String(localized: "Write and run a query that finds ") : String(localized: "Improve this query and run it: \(trimmed)")
                    dismiss()
                    onAskAgent(request)
                }
                .accessibilityIdentifier("graph-query-ask-agent")
            }
        }
    }

    private var savedQueries: some View {
        Section("Saved Queries") {
            ForEach(saved) { query in
                Button {
                    text = query.query
                    Task { await run(query.query) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(query.name).foregroundStyle(.primary)
                        if let description = query.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(query.query).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("graph-saved-query-\(query.id)")
                .contextMenu { deleteButton(query) }
                #if os(iOS)
                .swipeActions { deleteButton(query) }
                #endif
            }
        }
    }

    @ViewBuilder
    private func deleteButton(_ query: GraphSavedQuery) -> some View {
        if model.canEdit {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = query }
        }
    }

    private var examples: some View {
        Section {
            DisclosureGroup("Examples") {
                ForEach(Self.exampleQueries, id: \.self) { example in
                    Button(example) { text = example }
                        .font(.caption.monospaced())
                        .buttonStyle(.plain)
                }
            }
        } footer: {
            Text("A read-only subset of Cypher: MATCH, WHERE, RETURN and LIMIT.")
        }
    }

    private static let exampleQueries = [
        "MATCH (n:Person) RETURN n",
        "MATCH (a)-[r:KNOWS]->(b) RETURN a, r, b",
        "MATCH (a {name: \"Ada\"})-[*1..2]-(b) RETURN b",
        "MATCH (n) WHERE n.age >= 30 AND n.city = \"Paris\" RETURN n",
        "MATCH (n) WHERE degree(n) = 0 RETURN n",
    ]

    private func run(_ query: String) async {
        isRunning = true
        defer { isRunning = false }
        do {
            let found = try await model.run(query: query, mode: mode)
            result = found
            if !found.nodeIds.isEmpty || !found.edgeIds.isEmpty { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Names a query to keep with the graph.
private struct GraphSaveQuerySheet: View {
    let model: GraphModel
    let query: String
    @State private var name = ""
    @State private var details = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("graph-query-name")
                TextField("Description", text: $details, axis: .vertical).lineLimit(1...4)
                Section("Query") {
                    Text(query).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Save Query")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            let id = GraphElementID.make(from: trimmed, taken: Set(model.document?.queries.map(\.id) ?? []))
                            let description = details.trimmingCharacters(in: .whitespacesAndNewlines)
                            let saved = GraphSavedQuery(id: id, name: trimmed, description: description.isEmpty ? nil : description, query: query)
                            if await model.apply([.upsertQuery(saved)], status: String(localized: "Saving…"), done: String(localized: "Query saved")) { dismiss() }
                        }
                    }
                    .disabled(model.status != nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("graph-query-name-save")
                }
            }
            .overlay { if let status = model.status { ActionStatusOverlay(status) } }
        }
        .interactiveDismissDisabled(model.status != nil)
        .summarySheetSize()
    }
}

/// Every node and edge, searchable: the way in for big graphs, and for VoiceOver.
struct GraphElementsSheet: View {
    let model: GraphModel
    let onOpen: (GraphElementRef) -> Void
    @State private var search = ""
    @State private var showsEdges = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if showsEdges {
                    ForEach(matchingEdges) { edge in
                        row(title: edge.label, detail: "\(model.node(edge.source)?.label ?? edge.source) → \(model.node(edge.target)?.label ?? edge.target)", element: .edge(edge.id))
                    }
                } else {
                    ForEach(matchingNodes) { node in
                        row(title: node.label, detail: node.types.joined(separator: ", "), element: .node(node.id))
                    }
                }
            }
            .overlay {
                if (showsEdges ? matchingEdges.isEmpty : matchingNodes.isEmpty) {
                    ContentUnavailableView(search.isEmpty ? "Nothing Here Yet" : "No Matches", systemImage: "circle.grid.cross")
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Elements", selection: $showsEdges) {
                    Text("Nodes").tag(false)
                    Text("Edges").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("graph-elements-kind")
            }
            .searchable(text: $search)
            .navigationTitle("Elements")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .summarySheetSize()
    }

    private var matchingNodes: [GraphNode] {
        let nodes = model.document?.nodes ?? []
        guard !search.isEmpty else { return nodes }
        return nodes.filter { $0.label.localizedCaseInsensitiveContains(search) || $0.types.contains { $0.localizedCaseInsensitiveContains(search) } }
    }

    private var matchingEdges: [GraphEdge] {
        let edges = model.document?.edges ?? []
        guard !search.isEmpty else { return edges }
        return edges.filter { $0.label.localizedCaseInsensitiveContains(search) }
    }

    private func row(title: String, detail: String, element: GraphElementRef) -> some View {
        Button {
            dismiss()
            onOpen(element)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("graph-element-\(element.id)")
    }
}
