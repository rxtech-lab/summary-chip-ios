import AgentMarkdownUI
import RichDocumentEditor
import SummaryKit
import SwiftUI

struct TodoDetailView: View {
    let environment: AppEnvironment
    let id: String
    @State private var list: TodoList?
    @State private var error: String?
    @State private var status: String?
    @State private var sheet: TodoSheet?
    @State private var summary: Summary?
    @State private var saving = false
    @State private var needsSave = false
    @State private var draft = TodoItem()
    @State private var hidesCompleted = false
    @State private var completedFeedback = 0
    @State private var addedFeedback = 0
    @State private var deletedFeedback = 0
    @State private var uploads = TodoAttachmentUploads()
    @State private var focus: TodoFocus?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let list {
                content(list)
            } else if let error {
                ContentUnavailableView { Label("Todo List Unavailable", systemImage: "checklist") }
                    description: { Text(error) } actions: { Button("Try Again") { Task { await load() } } }
            } else { ProgressView("Loading todo list…") }
        }
        .navigationTitle(list?.document.title ?? "Todo List")
        .summaryInlineNavigationTitle()
        .task(id: id) { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
        .onChange(of: focus) { old, _ in
            switch old {
            case .newItem: if sheet == nil { addDraft() }
            case .item(let itemID): commitItem(itemID)
            case nil: break
            }
        }
        .toolbar { toolbar }
        .sheet(item: $sheet) { target in
            switch target {
            case .edit:
                if let list { TodoEditorSheet(api: environment.api, existing: list) { self.list = $0; refreshCard() } }
            case .share:
                if let summary { ShareModeSheet(summary: summary, api: environment.api) { environment.library.upsert($0); Task { await load() } } }
            case .delete:
                if let summary { DeleteSummarySheet(api: environment.api, summary: summary) { environment.library.remove(id: id); dismiss() } }
            case .item(let draft):
                TodoItemEditorSheet(item: draft.item, api: environment.api, existing: !draft.isNew) { updated in
                    mutate { document in
                        if draft.isNew {
                            document.items.append(updated.mergingNewAttachments(from: self.draft, since: draft.item))
                        }
                        else if let index = document.items.firstIndex(where: { $0.id == updated.id }) {
                            document.items[index] = updated.mergingNewAttachments(from: document.items[index], since: draft.item)
                        }
                    }
                    if draft.isNew {
                        self.draft = TodoItem(deadline: updated.deadline)
                        addedFeedback += 1
                    }
                } onDelete: { delete(draft.item.id) }
            }
        }
        .overlay { if let status { ActionStatusOverlay(status) } }
        .overlay(alignment: .top) {
            if saving {
                Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: saving)
        .statusAlert("Couldn't Update Todo List", message: list == nil ? nil : error) { error = nil }
        .statusAlert("Couldn't Attach File", message: uploads.error) { uploads.error = nil }
        .sensoryFeedback(.success, trigger: completedFeedback)
        .sensoryFeedback(.impact(weight: .light), trigger: addedFeedback)
        .sensoryFeedback(.impact(weight: .medium), trigger: deletedFeedback)
        .sensoryFeedback(.error, trigger: uploads.error)
        .sensoryFeedback(.error, trigger: error)
    }

    // MARK: Content

    private func content(_ list: TodoList) -> some View {
        let visible = list.document.items.filter { !hidesCompleted || !$0.completed || focus == .item($0.id) }
        let hiddenCount = list.document.items.count - visible.count
        return ScrollViewReader { proxy in
            List {
                Section {
                    TodoProgressHeader(document: list.document)
                        .listRowSeparator(.hidden)
                    if !list.document.description.isEmpty {
                        MarkdownView(text: list.document.description, baseURL: nil)
                            .listRowSeparator(.hidden)
                    }
                }
                Section {
                    itemRows(visible, list: list, canMove: list.isOwner && hiddenCount == 0)
                    newItemRow(list)
                } footer: {
                    if hiddenCount > 0 {
                        Button("Show \(hiddenCount) Completed") { withAnimation { hidesCompleted = false } }
                            .font(.footnote)
                    }
                }
            }
            .todoListStyle()
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await load() }
            .safeAreaInset(edge: .bottom) { newItemButton(list, proxy: proxy) }
            .animation(.snappy, value: focus == nil)
        }
    }

    private func itemRows(_ items: [TodoItem], list: TodoList, canMove: Bool) -> some View {
        ForEach(items) { item in
            itemRow(item, list: list)
        }
        .onMove { source, destination in
            guard canMove else { return }
            mutate { $0.items.move(fromOffsets: source, toOffset: destination) }
        }
        .moveDisabled(!canMove)
    }

    private func itemRow(_ item: TodoItem, list: TodoList) -> some View {
        let owner = list.isOwner
        return TodoItemRow(item: itemBinding(item.id), editable: owner, listDeadline: list.document.deadline, focus: $focus,
                           pending: uploads.pending(for: item.id)) {
            toggle(item.id)
        } onReturn: {
            focus = nil
        } onChange: {
            scheduleSave()
        } onAttach: { files in
            attach(files, to: item.id)
        } onPasteError: { uploads.error = $0 } onLoadingAttachments: { uploads.loadingChanged($0) } onDetails: {
            sheet = .item(TodoItemDraft(item: item, isNew: false))
        }
        .swipeActions(edge: .leading) {
            if owner {
                Button(item.completed ? "Incomplete" : "Complete", systemImage: item.completed ? "circle" : "checkmark.circle") {
                    toggle(item.id)
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            if owner {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(item.id) }
                Button("Details", systemImage: "info.circle") { sheet = .item(TodoItemDraft(item: item, isNew: false)) }
            }
        }
    }

    @ViewBuilder private func newItemRow(_ list: TodoList) -> some View {
        if list.isOwner && list.document.items.count < 500 {
            let id = draft.id
            TodoNewItemRow(item: $draft, listDeadline: list.document.deadline, focus: $focus,
                           pending: uploads.pending(for: id), onReturn: { addDraft() },
                           onPasteLines: addLines, onAttach: { attach($0, to: id) },
                           onPasteError: { uploads.error = $0 }, onLoadingAttachments: { uploads.loadingChanged($0) }) {
                sheet = .item(TodoItemDraft(item: draft, isNew: true))
            }
            .id(Self.newItemRowID)
        } else if list.document.items.isEmpty {
            Text("No items yet").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func newItemButton(_ list: TodoList, proxy: ScrollViewProxy) -> some View {
        if list.isOwner && focus == nil && list.document.items.count < 500 {
            HStack {
                Button {
                    focus = .newItem
                    withAnimation { proxy.scrollTo(Self.newItemRowID, anchor: .bottom) }
                } label: {
                    Label("New Item", systemImage: "plus.circle.fill").font(.headline)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("todo-new-item-button")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if focus != nil {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { focus = nil } }
        } else if list?.isOwner == true {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", systemImage: "pencil") { sheet = .edit }
                    .disabled(saving || needsSave || uploads.isBusy)
            }
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Button(hidesCompleted ? "Show Completed" : "Hide Completed", systemImage: hidesCompleted ? "eye" : "eye.slash") {
                    withAnimation { hidesCompleted.toggle() }
                }
                Divider()
                Button("Share…", systemImage: "square.and.arrow.up") { open(.share) }
                if list?.isOwner == true { Button("Delete Todo List", systemImage: "trash", role: .destructive) { open(.delete) } }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .disabled(list == nil)
        }
    }

    // MARK: Editing

    private static let newItemRowID = "todo-new-item-row"

    private func itemBinding(_ itemID: String) -> Binding<TodoItem> {
        Binding {
            list?.document.items.first { $0.id == itemID } ?? TodoItem(id: itemID)
        } set: { updated in
            guard let index = list?.document.items.firstIndex(where: { $0.id == itemID }) else { return }
            list?.document.items[index] = updated
        }
    }
    /// Applies a change locally right away, then saves it in the background.
    private func mutate(_ change: (inout TodoDocument) -> Void) {
        guard list?.isOwner == true else { return }
        change(&list!.document)
        scheduleSave()
    }
    private func toggle(_ itemID: String) {
        var completed = false
        mutate { document in
            guard let index = document.items.firstIndex(where: { $0.id == itemID }) else { return }
            document.items[index].completed.toggle()
            completed = document.items[index].completed
        }
        if completed { completedFeedback += 1 }
    }
    private func delete(_ itemID: String) {
        if focus == .item(itemID) { focus = nil }
        withAnimation { mutate { $0.items.removeAll { $0.id == itemID } } }
        deletedFeedback += 1
    }
    /// Called when an inline title loses focus: an emptied title deletes the item, like Reminders.
    private func commitItem(_ itemID: String) {
        guard let item = list?.document.items.first(where: { $0.id == itemID }) else { return }
        if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { delete(itemID) } else { scheduleSave() }
    }
    private func attach(_ files: [PastedAttachment], to id: String) {
        let item = draft.id == id ? draft : list?.document.items.first { $0.id == id }
        guard let item else { return }
        uploads.upload(files, to: item, api: environment.api) { attachment in
            if draft.id == id {
                draft.attachments.append(attachment)
            } else if let index = list?.document.items.firstIndex(where: { $0.id == id }) {
                mutate { $0.items[index].attachments.append(attachment) }
            }
        }
    }

    private func addDraft() {
        guard let list, list.document.items.count < 500,
              let item = draft.readyToAdd(pending: uploads.pending(for: draft.id)) else { return }
        draft = TodoItem(deadline: draft.deadline)
        withAnimation(.snappy) { mutate { $0.items.append(item) } }
        addedFeedback += 1
    }

    private func addLines(_ lines: [String]) {
        guard let list else { return }
        let items = TodoItem.pastedLines(lines, deadline: draft.deadline, limit: 500 - list.document.items.count)
        guard !items.isEmpty else { return }
        withAnimation(.snappy) { mutate { $0.items.append(contentsOf: items) } }
        addedFeedback += 1
    }

    // MARK: Persistence

    private func scheduleSave() {
        needsSave = true
        guard !saving else { return }
        Task { await flush() }
    }
    /// Saves serially. Edits made while a request is in flight stay local and go out in the next pass,
    /// so typing quickly never races the revision check.
    private func flush() async {
        guard !saving, needsSave else { return }
        saving = true
        defer { saving = false }
        while needsSave, let current = list {
            needsSave = false
            let snapshot = current.document
            do {
                var saved = try await environment.api.updateTodoList(id: id, document: snapshot.sanitizedForSave(), revision: current.revision)
                if let local = list?.document { saved.document = local }
                list = saved
            } catch {
                self.error = error.localizedDescription
                needsSave = false
                // Reload so the next edit starts from the latest revision.
                self.list = (try? await environment.api.todoList(id: id)) ?? self.list
                return
            }
        }
        refreshCard()
    }
    private func load() async {
        // Don't clobber an inline edit or a pending save with a background refresh.
        guard !saving, !needsSave, focus == nil else { return }
        do {
            let loaded = try await environment.api.todoList(id: id)
            guard !saving, !needsSave, focus == nil else { return }
            list = loaded; error = nil
            if draft.title.isEmpty && draft.attachments.isEmpty { draft.deadline = loaded.document.deadline }
        } catch { self.error = error.localizedDescription }
    }
    private func refreshCard() {
        Task { if let updated = try? await environment.api.summary(id: id) { environment.library.upsert(updated) } }
    }
    private func open(_ target: TodoSheet) {
        status = String(localized: "Loading…")
        Task {
            defer { status = nil }
            do { summary = try await environment.api.summary(id: id); sheet = target }
            catch { self.error = error.localizedDescription }
        }
    }
}

private enum TodoSheet: Identifiable {
    case edit, share, delete, item(TodoItemDraft)
    var id: String {
        switch self {
        case .edit: "edit"
        case .share: "share"
        case .delete: "delete"
        case .item(let draft): "item-\(draft.id)"
        }
    }
}

/// Progress ring plus deadline summary shown above the checklist.
private struct TodoProgressHeader: View {
    let document: TodoDocument
    private var done: Int { document.items.filter(\.completed).count }
    private var fraction: Double { document.items.isEmpty ? 0 : Double(done) / Double(document.items.count) }
    private var overdue: Bool { !document.isCompleted && document.deadline < .now }
    private var tint: Color {
        if !document.items.isEmpty && document.isCompleted { return .green }
        return overdue ? .red : .accentColor
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.fill.tertiary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if !document.items.isEmpty && document.isCompleted {
                    Image(systemName: "checkmark").font(.headline.bold()).foregroundStyle(tint)
                } else {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
            .frame(width: 56, height: 56)
            .animation(.snappy, value: fraction)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.items.isEmpty ? "No items yet" : "\(done) of \(document.items.count) completed")
                    .font(.headline)
                    .contentTransition(.numericText())
                Label {
                    Text(document.deadline, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                } icon: { Image(systemName: overdue ? "exclamationmark.circle.fill" : "calendar.badge.clock") }
                    .font(.subheadline)
                    .foregroundStyle(overdue ? Color.red : .secondary)
                Text(document.deadline, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    @ViewBuilder func todoListStyle() -> some View {
        #if os(iOS)
        listStyle(.plain)
        #else
        listStyle(.inset)
        #endif
    }
}
