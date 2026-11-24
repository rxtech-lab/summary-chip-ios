import SummaryKit
import SwiftUI

/// Quick filters apply immediately. More Filters opens the searchable sheet.
struct LibraryFilterMenu: View {
    let model: LibraryModel
    let showViewedResumes: () -> Void
    let showMoreFilters: () -> Void
    let applyFilter: (LibraryFilter) -> Void

    var body: some View {
        Menu {
            Button("Viewed Résumé Links", systemImage: "person.text.rectangle") { showViewedResumes() }
            Picker("Show", selection: filterBinding(\.scope)) {
                ForEach(LibraryScope.filterCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.inline)

            if model.kind == nil {
                Picker("Kind", selection: filterBinding(\.kind)) {
                    Text("All").tag(SummaryKind?.none)
                    ForEach(model.availableKinds) { kind in
                        Text(kind.title).tag(SummaryKind?.some(kind))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("library-filter-kind")
            }

            if model.filter.scope != .viewed {
                Picker("Visibility", selection: filterBinding(\.visibility)) {
                    Text("All").tag(SummaryVisibility?.none)
                    ForEach(SummaryVisibility.allCases) { value in
                        Text(value.title).tag(SummaryVisibility?.some(value))
                    }
                }
                .pickerStyle(.menu)
            }

            Picker("Source", selection: filterBinding(\.source)) {
                Text("Any source").tag(SummaryOrigin?.none)
                ForEach(SummaryOrigin.known) { origin in
                    Label { Text(origin.title) } icon: { origin.image }.tag(SummaryOrigin?.some(origin))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("library-filter-source")

            if model.kind == nil || model.kind == .summary || model.kind == .podcast {
                Toggle("Editor’s Pick", isOn: filterBinding(\.editorsPick))
                    .accessibilityIdentifier("library-filter-editors-pick")
            }

            Divider()

            Button {
                showMoreFilters()
            } label: {
                Label("More Filters…", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("library-filter-more")

            if model.filter.isActive {
                Button(role: .destructive) {
                    applyFilter(LibraryFilter())
                } label: {
                    Label("Clear All Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Label("Filter", systemImage: model.filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .badge(model.filter.activeCount)
        .accessibilityIdentifier("library-filter")
    }

    private func filterBinding<Value>(_ keyPath: WritableKeyPath<LibraryFilter, Value>) -> Binding<Value> {
        Binding {
            model.filter[keyPath: keyPath]
        } set: { value in
            var filter = model.filter
            filter[keyPath: keyPath] = value
            // Viewed summaries are always public; a visibility filter would only hide them.
            if filter.scope == .viewed { filter.visibility = nil }
            applyFilter(filter)
        }
    }

}
