import PhotosUI
import RichDocumentEditor
import SummaryKit
import SwiftUI

struct TodoEditorSheet: View {
    let api: SummaryAPIClient
    var existing: TodoList?
    let onSaved: (TodoList) -> Void
    @State private var document: TodoDocument
    @State private var editingItem: TodoItemDraft?
    @State private var draft: TodoItem
    @State private var showsDescription = false
    @State private var saving = false
    @State private var error: String?
    @State private var visibility: SummaryVisibility
    @State private var addedItems = 0
    @State private var uploads = TodoAttachmentUploads()
    @State private var focus: TodoFocus?
    @Environment(\.dismiss) private var dismiss

    init(api: SummaryAPIClient, existing: TodoList? = nil, onSaved: @escaping (TodoList) -> Void) {
        self.api = api; self.existing = existing; self.onSaved = onSaved
        let document = existing?.document ?? TodoDocument()
        _document = State(initialValue: document)
        _draft = State(initialValue: TodoItem(deadline: document.deadline))
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
                    ForEach($document.items) { $item in
                        let id = item.id
                        TodoItemRow(item: $item, editable: true, listDeadline: document.deadline, focus: $focus,
                                    pending: uploads.pending(for: id)) {
                            item.completed.toggle()
                        } onReturn: { focus = nil } onChange: {} onAttach: { files in
                            attach(files, to: id)
                        } onPasteError: { uploads.error = $0 } onLoadingAttachments: { uploads.loadingChanged($0) } onDetails: {
                            editingItem = TodoItemDraft(item: item, isNew: false)
                        }
                    }
                    .onDelete { document.items.remove(atOffsets: $0) }
                    .onMove { document.items.move(fromOffsets: $0, toOffset: $1) }
                    if document.items.count < 500 {
                        let id = draft.id
                        TodoNewItemRow(item: $draft, listDeadline: document.deadline, focus: $focus,
                                       pending: uploads.pending(for: id), onReturn: { addDraft() },
                                       onPasteLines: addLines, onAttach: { attach($0, to: id) },
                                       onPasteError: { uploads.error = $0 }, onLoadingAttachments: { uploads.loadingChanged($0) }) {
                            editingItem = TodoItemDraft(item: draft, isNew: true)
                        }
                    }
                } header: { Text("Items") } footer: {
                    Text("Press Return to add the next item and Shift-Return for a new line. Paste images or files into an item to attach them. Unfinished items and lists send a reminder when their deadlines are reached.")
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("todo-editor-form")
            .navigationTitle(existing == nil ? "New Todo List" : "Edit Todo List")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || uploads.isBusy || document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || document.title.count > 200)
                        .accessibilityIdentifier("todo-save")
                }
            }
            .onChange(of: focus) { old, _ in
                switch old {
                case .newItem: if editingItem == nil { addDraft() }
                case .item(let id): document.items.removeAll { $0.id == id && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                case nil: break
                }
            }
            .sheet(item: $editingItem) { draft in
                TodoItemEditorSheet(item: draft.item, api: api, existing: !draft.isNew) { updated in
                    if draft.isNew {
                        let merged = updated.mergingNewAttachments(from: self.draft, since: draft.item)
                        self.draft = TodoItem(deadline: updated.deadline)
                        document.items.append(merged)
                        addedItems += 1
                    } else if let index = document.items.firstIndex(where: { $0.id == updated.id }) {
                        document.items[index] = updated.mergingNewAttachments(from: document.items[index], since: draft.item)
                    }
                } onDelete: { document.items.removeAll { $0.id == draft.item.id } }
            }
            .sheet(isPresented: $showsDescription) {
                MarkdownEditorSheet(api: api, markdown: document.description) { document.description = $0 }
            }
            .overlay { if saving { ActionStatusOverlay(String(localized: "Saving todo list…")) } }
            .statusAlert("Couldn't Save Todo List", message: error) { error = nil }
            .statusAlert("Couldn't Attach File", message: uploads.error) { uploads.error = nil }
            .sensoryFeedback(.error, trigger: uploads.error)
            .sensoryFeedback(.error, trigger: error)
            .sensoryFeedback(.selection, trigger: editingItem?.id)
            .sensoryFeedback(.impact(weight: .light), trigger: addedItems)
        }
        .interactiveDismissDisabled(saving || uploads.isBusy)
        .summarySheetFrame(minWidth: 560, idealWidth: 640, minHeight: 540)
    }
    private func attach(_ files: [PastedAttachment], to id: String) {
        let item = draft.id == id ? draft : document.items.first { $0.id == id }
        guard let item else { return }
        uploads.upload(files, to: item, api: api) { attachment in
            if draft.id == id { draft.attachments.append(attachment) }
            else if let index = document.items.firstIndex(where: { $0.id == id }) {
                document.items[index].attachments.append(attachment)
            }
        }
    }

    private func addDraft() {
        guard document.items.count < 500, let item = draft.readyToAdd(pending: uploads.pending(for: draft.id)) else { return }
        draft = TodoItem(deadline: draft.deadline)
        withAnimation(.snappy) { document.items.append(item) }
        addedItems += 1
    }

    private func addLines(_ lines: [String]) {
        let items = TodoItem.pastedLines(lines, deadline: draft.deadline, limit: 500 - document.items.count)
        withAnimation(.snappy) { document.items.append(contentsOf: items) }
        if !items.isEmpty { addedItems += 1 }
    }

    private func save() async {
        guard !saving, !uploads.isBusy else { return }
        addDraft()
        saving = true
        defer { saving = false }
        do {
            let clean = document.sanitizedForSave()
            let saved: TodoList
            if let existing { saved = try await api.updateTodoList(id: existing.id, document: clean, revision: existing.revision) }
            else { saved = try await api.createTodoList(clean, visibility: visibility) }
            onSaved(saved); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct TodoItemDraft: Identifiable {
    var item: TodoItem
    var isNew: Bool
    var id: String { item.id }
}

struct TodoItemEditorSheet: View {
    @State var item: TodoItem
    let api: SummaryAPIClient
    @State private var uploads = TodoAttachmentUploads()
    @State private var focused = false
    let existing: Bool
    let onSave: (TodoItem) -> Void
    let onDelete: () -> Void
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ComposerTextView("Title", text: $item.title, isFocused: $focused,
                                     accessibilityIdentifier: "todo-item-title", onSubmit: { focused = false },
                                     onPasteAttachments: attach, onPasteError: { uploads.error = $0 },
                                     onLoadingAttachments: { uploads.loadingChanged($0) })
                    Toggle("Completed", isOn: $item.completed)
                }
                Section("Attachments") {
                    TodoAttachButton(onPick: attach, onLoading: { uploads.loadingChanged($0) })
                    TodoAttachmentStrip(attachments: item.attachments, pending: uploads.pending, canRemove: true) { attachment in
                        item.attachments.removeAll { $0.id == attachment.id }
                    }
                }
                Section("Deadline") {
                    DatePicker("Deadline", selection: $item.deadline)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(TodoQuickDate.allCases) { option in
                                Button { item.deadline = option.date() } label: {
                                    TodoChip(Text(option.title), systemImage: option.systemImage)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
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
                    Button("Done") {
                        if let updated = item.readyToAdd(pending: []) { onSave(updated); dismiss() }
                    }
                    .disabled(uploads.isBusy || item.readyToAdd(pending: []) == nil || item.title.count > 300)
                }
            }
            .confirmationDialog("Delete this item?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete Item", role: .destructive) { onDelete(); dismiss() }
            }
            .statusAlert("Couldn't Attach File", message: uploads.error) { uploads.error = nil }
            .sensoryFeedback(.error, trigger: uploads.error)
            .sensoryFeedback(.selection, trigger: item.completed)
            .sensoryFeedback(.selection, trigger: item.deadline)
        }
        .summarySheetFrame(minWidth: 560, idealWidth: 640, minHeight: 540)
    }

    private func attach(_ files: [PastedAttachment]) {
        uploads.upload(files, to: item, api: api) { item.attachments.append($0) }
    }
}

// MARK: - Shared rows

enum TodoFocus: Hashable { case newItem, item(String) }

extension TodoItem {
    func readyToAdd(pending: [TodoAttachmentUploads.Pending]) -> TodoItem? {
        var result = self
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = attachments.first?.name ?? pending.first?.name ?? ""
        result.title = String((trimmed.isEmpty ? fallback : trimmed).prefix(300))
        return result.title.isEmpty ? nil : result
    }

    static func pastedLines(_ lines: [String], deadline: Date, limit: Int) -> [TodoItem] {
        Array(lines.lazy.compactMap { TodoItem(title: $0, deadline: deadline).readyToAdd(pending: []) }.prefix(max(0, limit)))
    }

    func mergingNewAttachments(from current: TodoItem, since original: TodoItem) -> TodoItem {
        var result = self
        let known = Set((attachments + original.attachments).map(\.id))
        result.attachments += current.attachments.filter { !known.contains($0.id) }
        return result
    }
}

extension TodoDocument {
    /// The server rejects blank or overlong titles; trim them and drop items left empty mid-edit.
    func sanitizedForSave() -> TodoDocument {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.items = items.compactMap { item in
            var item = item
            item.title = String(item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            return item.title.isEmpty ? nil : item
        }
        return copy
    }
}

enum TodoQuickDate: String, CaseIterable, Identifiable {
    case today, tomorrow, nextWeek
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .today: "Today"; case .tomorrow: "Tomorrow"; case .nextWeek: "Next Week" }
    }
    var systemImage: String {
        switch self { case .today: "sun.max"; case .tomorrow: "sunrise"; case .nextWeek: "calendar" }
    }
    func date(now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .today:
            let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
            return evening > now ? evening : now.addingTimeInterval(3600)
        case .tomorrow:
            let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
            return calendar.date(byAdding: .day, value: 1, to: morning) ?? now.addingTimeInterval(86400)
        case .nextWeek:
            return calendar.nextDate(after: now, matching: DateComponents(hour: 9, weekday: calendar.firstWeekday),
                                     matchingPolicy: .nextTime) ?? now.addingTimeInterval(7 * 86400)
        }
    }
}

func todoDeadlineColor(_ date: Date, completed: Bool) -> Color {
    if completed { return .secondary }
    if date < .now { return .red }
    if Calendar.current.isDateInToday(date) { return .orange }
    return .secondary
}

/// Item attachments upload in the background. Each upload remembers which row it belongs to, so a
/// draft submitted mid-upload still receives its file once the upload finishes.
@MainActor @Observable final class TodoAttachmentUploads {
    struct Pending: Identifiable {
        let id = UUID()
        let itemID: String
        let name: String
        var bytesSent: Int64 = 0
        let totalBytes: Int64
        var progress: Double { totalBytes > 0 ? Double(bytesSent) / Double(totalBytes) : 0 }
    }
    static let maxPerItem = 20
    private(set) var pending: [Pending] = []
    private var loadingCount = 0
    var isBusy: Bool { loadingCount > 0 || !pending.isEmpty }
    func loadingChanged(_ started: Bool) { loadingCount += started ? 1 : -1 }
    var error: String?

    func pending(for id: String) -> [Pending] { pending.filter { $0.itemID == id } }

    func upload(_ files: [PastedAttachment], to item: TodoItem, api: SummaryAPIClient,
                onFinished: @escaping (TodoAttachment) -> Void) {
        let room = Self.maxPerItem - item.attachments.count - pending(for: item.id).count
        if files.count > room { error = String(localized: "An item can have up to \(Self.maxPerItem) attachments.") }
        for file in files.prefix(max(0, room)) {
            guard file.data.count <= SummaryAPIClient.documentFileMaxBytes else {
                error = String(localized: "\(file.filename) is larger than 25 MB."); continue
            }
            let upload = Pending(itemID: item.id, name: file.filename, totalBytes: Int64(file.data.count))
            pending.append(upload)
            Task {
                do {
                    let attachment = try await api.uploadDocumentFile(data: file.data, filename: file.filename, mimeType: file.mimeType) { sent, _ in
                        Task { @MainActor in self.setProgress(upload.id, sent) }
                    }
                    pending.removeAll { $0.id == upload.id }
                    onFinished(attachment)
                } catch {
                    pending.removeAll { $0.id == upload.id }
                    self.error = error.localizedDescription
                }
            }
        }
    }
    private func setProgress(_ id: UUID, _ bytesSent: Int64) {
        if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].bytesSent = min(bytesSent, pending[index].totalBytes) }
    }
}

struct TodoChip: View {
    let title: Text
    let systemImage: String
    var tint: Color = .secondary
    init(_ title: Text, systemImage: String, tint: Color = .secondary) {
        self.title = title; self.systemImage = systemImage; self.tint = tint
    }
    var body: some View {
        Label { title } icon: { Image(systemName: systemImage) }
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Deadline chip that offers quick dates; "Custom…" opens the item's details sheet.
struct TodoDeadlineMenu: View {
    @Binding var deadline: Date
    let listDeadline: Date
    var completed = false
    let onChange: () -> Void
    let onCustom: () -> Void
    var body: some View {
        Menu {
            ForEach(TodoQuickDate.allCases) { option in
                Button(option.title, systemImage: option.systemImage) { deadline = option.date(); onChange() }
            }
            Button("List Deadline", systemImage: "flag.checkered") { deadline = listDeadline; onChange() }
            Divider()
            Button("Custom…", systemImage: "calendar.badge.clock", action: onCustom)
        } label: {
            TodoChip(Text(deadline, format: .dateTime.month().day().hour().minute()), systemImage: "calendar",
                     tint: todoDeadlineColor(deadline, completed: completed))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Change deadline")
    }
}

/// Paperclip chip: pick photos or files. Pasting into the field does the same without the menu.
struct TodoAttachButton: View {
    let onPick: ([PastedAttachment]) -> Void
    let onLoading: (Bool) -> Void
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var error: String?
    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotos = true }
            Button("Choose File…", systemImage: "folder") { showsFiles = true }
        } label: {
            TodoChip(Text("Attach"), systemImage: "paperclip")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .photosPicker(isPresented: $showsPhotos, selection: $photos, maxSelectionCount: TodoAttachmentUploads.maxPerItem, matching: .images)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { onPick(try result.get().map(PastedAttachment.load(fileURL:))) }
            catch let error as CocoaError where error.code == .userCancelled { }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: photos) { _, selected in
            guard !selected.isEmpty else { return }
            onLoading(true)
            Task {
                defer { onLoading(false); photos = [] }
                var loaded: [PastedAttachment] = []
                for (index, photo) in selected.enumerated() {
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
                        let type = photo.supportedContentTypes.first ?? .jpeg
                        loaded.append(.normalized(data: data, filename: "Photo \(index + 1).\(type.preferredFilenameExtension ?? "jpg")", type: type))
                    } catch { self.error = error.localizedDescription }
                }
                if !loaded.isEmpty { onPick(loaded) }
            }
        }
        .statusAlert("Couldn't Attach File", message: error) { error = nil }
    }
}

/// Thumbnails for an item's attachments plus in-flight uploads. Tapping opens the file.
struct TodoAttachmentStrip: View {
    let attachments: [TodoAttachment]
    let pending: [TodoAttachmentUploads.Pending]
    let canRemove: Bool
    let onRemove: (TodoAttachment) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !attachments.isEmpty || !pending.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        Button { openURL(attachment.url) } label: { tile(attachment) }
                            .accessibilityLabel(attachment.name)
                            .accessibilityIdentifier("todo-attachment-\(attachment.name)")
                            .buttonStyle(.plain)
                            .overlay(alignment: .topTrailing) {
                                if canRemove {
                                    Button("Remove \(attachment.name)", systemImage: "xmark.circle.fill") {
                                        withAnimation(.snappy) { onRemove(attachment) }
                                    }
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    ForEach(pending) { upload in
                        pendingTile(upload).transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 6)
                .padding(.trailing, 6)
            }
            .scrollIndicators(.hidden)
            .animation(.spring(duration: 0.35, bounce: 0.3), value: attachments.map(\.id))
            .animation(.spring(duration: 0.35, bounce: 0.3), value: pending.map(\.id))
        }
    }

    @ViewBuilder private func tile(_ attachment: TodoAttachment) -> some View {
        if attachment.isImage {
            AsyncImage(url: attachment.url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                default: ProgressView().controlSize(.small)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityLabel(attachment.name)
        } else {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(for: attachment.contentType)).font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name).font(.caption.weight(.medium)).lineLimit(2)
                    Text(Int64(attachment.size), format: .byteCount(style: .file)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 168, height: 64, alignment: .leading)
            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
        }
    }

    private func pendingTile(_ upload: TodoAttachmentUploads.Pending) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(upload.name).font(.caption.weight(.medium)).lineLimit(1)
            ProgressView(value: upload.progress)
            HStack {
                Text(upload.progress, format: .percent.precision(.fractionLength(0)))
                Spacer(minLength: 4)
                Text("\(upload.bytesSent.formatted(.byteCount(style: .file))) / \(upload.totalBytes.formatted(.byteCount(style: .file)))")
            }
            .font(.caption2)
            .monospacedDigit()
        }
        .padding(8)
        .frame(width: 180, height: 64)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    static func symbol(for contentType: String) -> String {
        if contentType == "application/pdf" { return "doc.richtext" }
        if contentType.hasPrefix("video/") { return "film" }
        if contentType.hasPrefix("audio/") { return "waveform" }
        if contentType.hasPrefix("text/") { return "doc.text" }
        if contentType.contains("zip") { return "doc.zipper" }
        return "doc"
    }
}

struct TodoCheckButton: View {
    let item: TodoItem
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(item.completed ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: item.completed)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.completed ? "Mark \(item.title) incomplete" : "Complete \(item.title)")
    }
}

/// Bridges the row's focus enum to the composer's Bool.
private func focusBinding(_ focus: Binding<TodoFocus?>, _ target: TodoFocus) -> Binding<Bool> {
    Binding {
        focus.wrappedValue == target
    } set: { focused in
        if focused { focus.wrappedValue = target } else if focus.wrappedValue == target { focus.wrappedValue = nil }
    }
}

/// Owners can edit an item title in place and open its details.
struct TodoItemRow: View {
    @Binding var item: TodoItem
    let editable: Bool
    let listDeadline: Date
    @Binding var focus: TodoFocus?
    let pending: [TodoAttachmentUploads.Pending]
    let onToggle: () -> Void
    let onReturn: () -> Void
    let onChange: () -> Void
    let onAttach: ([PastedAttachment]) -> Void
    let onPasteError: (String) -> Void
    let onLoadingAttachments: (Bool) -> Void
    let onDetails: () -> Void
    @ScaledMetric(relativeTo: .body) private var lineHeight = 22
    private var isFocused: Bool { focus == .item(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TodoCheckButton(item: item, action: onToggle)
                .disabled(!editable)
                .frame(height: lineHeight)
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if editable && (!item.completed || isFocused) {
                        ComposerTextView("Title", text: $item.title, isFocused: focusBinding($focus, .item(item.id)),
                                         onSubmit: onReturn, onPasteAttachments: onAttach, onPasteError: onPasteError,
                                         onLoadingAttachments: onLoadingAttachments)
                    } else if editable {
                        Button { focus = .item(item.id) } label: { Text(item.title) }.buttonStyle(.plain)
                    } else {
                        Text(item.title)
                    }
                }
                .strikethrough(item.completed && !isFocused)
                .foregroundStyle(item.completed && !isFocused ? .secondary : .primary)
                TodoAttachmentStrip(attachments: item.attachments, pending: pending,
                                    canRemove: editable && isFocused) { attachment in
                    item.attachments.removeAll { $0.id == attachment.id }
                    onChange()
                }
                if isFocused {
                    TodoDeadlineMenu(deadline: $item.deadline, listDeadline: listDeadline, completed: item.completed,
                                     onChange: onChange, onCustom: onDetails)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    Label { Text(item.deadline, format: .dateTime.month().day().hour().minute()) }
                        icon: { Image(systemName: item.deadline < .now && !item.completed ? "exclamationmark.circle" : "calendar") }
                        .font(.caption)
                        .foregroundStyle(todoDeadlineColor(item.deadline, completed: item.completed))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if editable && isFocused {
                Button("Details", systemImage: "info.circle", action: onDetails)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .frame(height: lineHeight)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 4)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: isFocused)
        .animation(.snappy, value: item.completed)
    }
}

/// The trailing "New Item" composer. Return adds the item and keeps the cursor here for the next one.
struct TodoNewItemRow: View {
    @Binding var item: TodoItem
    let listDeadline: Date
    @Binding var focus: TodoFocus?
    let pending: [TodoAttachmentUploads.Pending]
    let onReturn: () -> Void
    let onPasteLines: ([String]) -> Void
    let onAttach: ([PastedAttachment]) -> Void
    let onPasteError: (String) -> Void
    let onLoadingAttachments: (Bool) -> Void
    let onDetails: () -> Void
    @ScaledMetric(relativeTo: .body) private var lineHeight = 22
    private var isFocused: Bool { focus == .newItem }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isFocused ? "circle" : "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(isFocused ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: lineHeight)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                ComposerTextView("New Item", text: $item.title, isFocused: focusBinding($focus, .newItem),
                                 accessibilityIdentifier: "todo-new-item", onSubmit: onReturn, onPasteAttachments: onAttach,
                                 onPasteError: onPasteError, onPasteLines: item.attachments.isEmpty && pending.isEmpty ? onPasteLines : nil,
                                 onLoadingAttachments: onLoadingAttachments)
                TodoAttachmentStrip(attachments: item.attachments, pending: pending, canRemove: true) { attachment in
                    item.attachments.removeAll { $0.id == attachment.id }
                }
                if isFocused {
                    VStack(alignment: .leading, spacing: 8) {
                        TodoDeadlineMenu(deadline: $item.deadline, listDeadline: listDeadline, onChange: {}, onCustom: onDetails)
                        Text("Return to add · Shift-Return for a new line · Paste images or files")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isFocused {
                Button("Details", systemImage: "info.circle", action: onDetails)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .frame(height: lineHeight)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, isFocused ? 10 : 4)
        .padding(.horizontal, isFocused ? 10 : 0)
        .background {
                if isFocused {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.fill.quinary)
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.tint.opacity(0.35), lineWidth: 1) }
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focus = .newItem }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: isFocused)
    }
}
