import SummaryKit
import SwiftUI

/// Dedicated sheet for choosing what the library shows: created vs viewed, category, tag, visibility.
struct LibraryFilterSheet: View {
    let model: LibraryModel
    let onApply: (LibraryFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryFilter

    init(model: LibraryModel, onApply: @escaping (LibraryFilter) -> Void) {
        self.model = model
        self.onApply = onApply
        self._draft = State(initialValue: model.filter)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Show", selection: $draft.scope) {
                        ForEach(LibraryScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Show")
                } footer: {
                    Text("Viewed summaries are ones other people shared that you opened.")
                }

                if draft.scope != .viewed {
                    Section("Visibility") {
                        Picker("Visibility", selection: $draft.visibility) {
                            Text("All").tag(SummaryVisibility?.none)
                            ForEach(SummaryVisibility.allCases) { value in
                                Text(value.title).tag(SummaryVisibility?.some(value))
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                Section("Category") {
                    Picker("Category", selection: $draft.category) {
                        Text("Any category").tag(String?.none)
                        ForEach(categories, id: \.name) { facet in
                            HStack {
                                Text(facet.name)
                                Spacer()
                                if facet.count > 0 { Text("\(facet.count)").foregroundStyle(.secondary) }
                            }
                            .tag(String?.some(facet.name))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Tag") {
                    if model.facets.tags.isEmpty {
                        Text("Tags appear here once your library has summaries.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Tag", selection: $draft.tag) {
                            Text("Any tag").tag(String?.none)
                            ForEach(model.facets.tags) { facet in
                                HStack {
                                    Text("#\(facet.name)")
                                    Spacer()
                                    Text("\(facet.count)").foregroundStyle(.secondary)
                                }
                                .tag(String?.some(facet.name))
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }

                if draft.isActive {
                    Section {
                        Button("Clear All Filters", role: .destructive) { draft = LibraryFilter() }
                    }
                }
            }
            .onChange(of: draft.scope) { _, scope in
                // Viewed summaries are always public; a visibility filter would only hide them.
                if scope == .viewed { draft.visibility = nil }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task { await model.loadFacets() }
        }
    }

    /// Server facets first (with counts), then the rest of the closed category list.
    private var categories: [FacetCount] {
        let known = model.facets.categories
        let names = Set(known.map(\.name))
        return known + SummaryCategory.all.filter { !names.contains($0) }.map { FacetCount(name: $0, count: 0) }
    }
}
