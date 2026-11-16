import SummaryKit
import SwiftUI

struct TodoEditorSheet: View {
    let api: SummaryAPIClient
    var existing: TodoList?
    let onSaved: (TodoList) -> Void
    @State private var document: TodoDocument
    @State private var item: TodoItem?
    @State private var showsDescription = false
    @State private var saving = false
    @State private var error: String?
    @State private var visibility: SummaryVisibility
    @Environment(\.dismiss) private var dismiss

    init(api: SummaryAPIClient, existing: TodoList? = nil, onSaved: @escaping (TodoList) -> Void) {
        self.api = api; self.existing = existing; self.onSaved = onSaved
        _document = State(initialValue: existing?.document ?? TodoDocument())
        _visibility = State(initialValue: existing?.visibility ?? .private)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("List") {
                    TextField("Title", text: $document.title)
                        .accessibilityIdentifier("todo-title")
                    DatePicker("Deadline", selection: $document.deadline)
                    Button { showsDescription = true } label: {
                        Label(document.description.isEmpty ? "Add Description" : "Edit Description", systemImage: "doc.richtext")
                    }
                    if existing == nil {
                        Picker("Visibility", selection: $visibility) {
                            ForEach(SummaryVisibility.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                Section {
                    ForEach(document.items) { item in
                        Button { self.item = item } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(item.title, systemImage: item.completed ? "checkmark.circle.fill" : "circle")
                                Text(item.deadline, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Add Item", systemImage: "plus") { item = TodoItem(deadline: document.deadline) }
                        .disabled(document.items.count >= 500)
                } header: { Text("Items") } footer: {
                    Text("Each item has its own deadline. Unfinished items and lists send a reminder when their deadlines are reached.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "New Todo List" : "Edit Todo List")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || document.title.count > 200)
                        .accessibilityIdentifier("todo-save")
                }
            }
            .sheet(item: $item) { item in
                TodoItemEditorSheet(item: item, existing: document.items.contains { $0.id == item.id }) { updated in
                    if let index = document.items.firstIndex(where: { $0.id == updated.id }) { document.items[index] = updated }
                    else { document.items.append(updated) }
                } onDelete: { document.items.removeAll { $0.id == item.id } }
            }
            .sheet(isPresented: $showsDescription) {
                MarkdownEditorSheet(api: api, markdown: document.description) { document.description = $0 }
            }
            .overlay { if saving { ActionStatusOverlay(String(localized: "Saving todo list…")) } }
            .statusAlert("Couldn't Save Todo List", message: error) { error = nil }
            .sensoryFeedback(.error, trigger: error)
            .sensoryFeedback(.selection, trigger: item?.id)
        }
        .interactiveDismissDisabled(saving)
        .summarySheetSize()
    }
    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let saved: TodoList
            if let existing { saved = try await api.updateTodoList(id: existing.id, document: document, revision: existing.revision) }
            else { saved = try await api.createTodoList(document, visibility: visibility) }
            onSaved(saved); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct TodoItemEditorSheet: View {
    @State var item: TodoItem
    let existing: Bool
    let onSave: (TodoItem) -> Void
    let onDelete: () -> Void
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $item.title, axis: .vertical)
                    .accessibilityIdentifier("todo-item-title")
                DatePicker("Deadline", selection: $item.deadline)
                Toggle("Completed", isOn: $item.completed)
                if existing {
                    Section { Button("Delete Item", role: .destructive) { deleting = true } }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing ? "Edit Item" : "New Item")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(item); dismiss() }
                        .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.title.count > 300)
                }
            }
            .confirmationDialog("Delete this item?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete Item", role: .destructive) { onDelete(); dismiss() }
            }
            .sensoryFeedback(.selection, trigger: item.completed)
        }
        .summarySheetSize()
    }
}
