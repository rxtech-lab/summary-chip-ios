import SummaryKit
import SwiftUI

/// Dedicated sheet for choosing what the library shows: created vs viewed, source, category, tag, visibility.
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

                Section {
                    Picker("Source", selection: $draft.source) {
                        Text("Any source").tag(SummaryOrigin?.none)
                        ForEach(SummaryOrigin.known) { origin in
                            Label { Text(origin.title) } icon: { origin.image }.tag(SummaryOrigin?.some(origin))
                        }
                    }
                    .accessibilityIdentifier("library-filter-source")
                } footer: {
                    Text("Where the summarized content came from: a web page, a post or video, a GitHub page, a PDF, or text.")
                }

                Section {
                    FacetComboBox(
                        "Category",
                        anyTitle: "Any category",
                        emptyMessage: "No categories",
                        kind: .category,
                        api: model.api,
                        selection: $draft.category
                    )
                    FacetComboBox(
                        "Tag",
                        anyTitle: "Any tag",
                        emptyMessage: "Tags appear here once your library has summaries.",
                        kind: .tag,
                        api: model.api,
                        selection: $draft.tag,
                        label: { "#\($0)" }
                    )
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
            .formStyle(.grouped)
            .navigationTitle("Filter")
            .summaryInlineNavigationTitle()
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
        }
        .summarySheetSize()
    }
}
