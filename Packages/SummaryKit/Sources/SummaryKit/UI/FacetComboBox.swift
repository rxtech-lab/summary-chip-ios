import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Searches one facet list (`GET /api/v1/facets?kind=…`): the first 10 names, more as the list scrolls.
@MainActor
@Observable
public final class FacetSearchModel {
    public static let pageSize = 10

    public let kind: FacetKind
    private let api: SummaryAPIClient

    public var query = ""
    public private(set) var items: [FacetCount] = []
    public private(set) var nextCursor: String?
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?

    /// The query `items` answer, so paging continues the same search even while the user types.
    private var loadedQuery = ""
    private var generation = 0

    public init(kind: FacetKind, api: SummaryAPIClient) {
        self.kind = kind
        self.api = api
    }

    /// Server-side search term: tags are shown as `#tag`, so a typed `#` is not part of the name.
    private var term: String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return kind == .tag && trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    }

    /// Replaces the results with the first page matching `query`.
    public func search() async {
        generation += 1
        let generation = generation
        let term = term
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        do {
            let page = try await api.facets(kind: kind, query: term, limit: Self.pageSize)
            guard generation == self.generation else { return }
            items = page.items
            nextCursor = page.nextCursor
            loadedQuery = term
            errorMessage = nil
            hasLoaded = true
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard generation == self.generation else { return }
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    public func loadMore() async {
        guard let cursor = nextCursor, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = generation
        do {
            let page = try await api.facets(kind: kind, query: loadedQuery, cursor: cursor, limit: Self.pageSize)
            guard generation == self.generation else { return }
            let known = Set(items.map(\.name))
            items.append(contentsOf: page.items.filter { !known.contains($0.name) })
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Searches right away for the first load, debounced while typing.
    func searchDebounced() async {
        if hasLoaded { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        await search()
    }
}

/// A searchable facet picker. macOS: an editable combo box whose list searches as you type.
/// iOS: a row that opens a search sheet (a popover on iPad).
public struct FacetComboBox: View {
    private let title: String
    private let anyTitle: String
    private let emptyMessage: String
    private let label: (String) -> String
    @Binding private var selection: String?
    @State private var model: FacetSearchModel
    #if os(iOS)
    @State private var showsPicker = false
    #endif

    public init(
        _ title: String,
        anyTitle: String,
        emptyMessage: String,
        kind: FacetKind,
        api: SummaryAPIClient,
        selection: Binding<String?>,
        label: @escaping (String) -> String = { $0 }
    ) {
        self.title = title
        self.anyTitle = anyTitle
        self.emptyMessage = emptyMessage
        self.label = label
        self._selection = selection
        self._model = State(initialValue: FacetSearchModel(kind: kind, api: api))
    }

    public var body: some View {
        #if os(macOS)
        LabeledContent(title) {
            FacetComboBoxField(
                placeholder: anyTitle,
                items: model.items,
                hasMore: model.nextCursor != nil,
                label: label,
                selection: $selection,
                onQuery: { model.query = $0 },
                onLoadMore: { Task { await model.loadMore() } }
            )
        }
        .task(id: model.query) { await model.searchDebounced() }
        #else
        Button { showsPicker = true } label: {
            LabeledContent(title) {
                HStack(spacing: 4) {
                    Text(selection.map(label) ?? anyTitle)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsPicker) {
            FacetSearchSheet(
                model: model,
                title: title,
                anyTitle: anyTitle,
                emptyMessage: emptyMessage,
                label: label,
                selection: $selection
            )
            .frame(minWidth: 320, idealWidth: 360, minHeight: 420, idealHeight: 520)
            .presentationDetents([.medium, .large])
        }
        #endif
    }
}

#if os(iOS)
/// The iPhone sheet (iPad popover) behind `FacetComboBox`: type to search, scroll to load more.
private struct FacetSearchSheet: View {
    @Bindable var model: FacetSearchModel
    let title: String
    let anyTitle: String
    let emptyMessage: String
    let label: (String) -> String
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.query.isEmpty {
                    row(anyTitle, value: nil, count: nil)
                }
                ForEach(model.items) { facet in
                    row(label(facet.name), value: facet.name, count: facet.count)
                        .onAppear {
                            if facet.name == model.items.last?.name { Task { await model.loadMore() } }
                        }
                }
                if model.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .overlay { emptyState }
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: model.query) { await model.searchDebounced() }
            .navigationTitle(title)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ text: String, value: String?, count: Int?) -> some View {
        Button {
            selection = value
            dismiss()
        } label: {
            HStack {
                Text(text)
                Spacer()
                if let count, count > 0 { Text("\(count)").foregroundStyle(.secondary) }
                if selection == value {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.items.isEmpty {
            if !model.hasLoaded || model.isLoading {
                if !model.query.isEmpty { ProgressView() }
            } else if let message = model.errorMessage {
                ContentUnavailableView("Couldn't Load", systemImage: "wifi.exclamationmark", description: Text(message))
            } else if !model.query.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                ContentUnavailableView(emptyMessage, systemImage: "tag")
            }
        }
    }
}
#endif

#if os(macOS)
/// `NSComboBox` backed by the facet search: typing filters the list on the server, scrolling to the
/// end of the list loads the next page. Text that matches no facet reverts to the current selection.
private struct FacetComboBoxField: NSViewRepresentable {
    let placeholder: String
    let items: [FacetCount]
    let hasMore: Bool
    let label: (String) -> String
    @Binding var selection: String?
    let onQuery: (String) -> Void
    let onLoadMore: () -> Void

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = true
        box.dataSource = context.coordinator
        box.delegate = context.coordinator
        box.completes = true
        box.numberOfVisibleItems = FacetSearchModel.pageSize
        box.placeholderString = placeholder
        box.stringValue = selection.map(label) ?? ""
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        box.placeholderString = placeholder
        box.reloadData()
        if box.currentEditor() == nil { box.stringValue = selection.map(label) ?? "" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: FacetComboBoxField

        init(parent: FacetComboBoxField) {
            self.parent = parent
        }

        func numberOfItems(in comboBox: NSComboBox) -> Int { parent.items.count }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            guard parent.items.indices.contains(index) else { return nil }
            if index == parent.items.count - 1, parent.hasMore { parent.onLoadMore() }
            return parent.label(parent.items[index].name)
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            let typed = string.lowercased()
            return parent.items.map { parent.label($0.name) }.first { $0.lowercased().hasPrefix(typed) }
        }

        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            parent.items.firstIndex { parent.label($0.name) == string } ?? NSNotFound
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, parent.items.indices.contains(box.indexOfSelectedItem) else { return }
            parent.selection = parent.items[box.indexOfSelectedItem].name
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.onQuery(box.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            let text = box.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            if text.isEmpty {
                parent.selection = nil
            } else if let match = parent.items.first(where: { parent.label($0.name).lowercased() == text || $0.name.lowercased() == text }) {
                parent.selection = match.name
            }
            box.stringValue = parent.selection.map(parent.label) ?? ""
            // Show the most used names again the next time the list opens.
            parent.onQuery("")
        }
    }
}
#endif
