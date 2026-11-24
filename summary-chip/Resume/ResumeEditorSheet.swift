import SwiftUI
import SummaryKit
import UniformTypeIdentifiers


private struct ResumeItemsEditor<Item: Identifiable, Editor: View>: View where Item.ID == String {
    let label: String
    @Binding var items: [Item]
    let newItem: () -> Item
    let name: (Item) -> String
    @ViewBuilder let editor: (Binding<Item>) -> Editor
    @State private var addition: Item?
    @State private var removal: Item?

    var body: some View {
        Section(label) {
            ForEach($items) { $item in
                NavigationLink { editor($item).navigationTitle(name(item)) } label: { Text(name(item)) }
                    .contextMenu {
                        Button("Move Up") { move(item.id, by: -1) }.disabled(items.first?.id == item.id)
                        Button("Move Down") { move(item.id, by: 1) }.disabled(items.last?.id == item.id)
                        Button("Remove", role: .destructive) { removal = item }
                    }
            }.onMove { items.move(fromOffsets: $0, toOffset: $1) }
            Button("Add", systemImage: "plus") { addition = newItem() }
        }
        .sheet(item: $addition) { initial in
            ResumeItemCreation(item: initial, editor: editor) { items.append($0) }
        }
        .confirmationDialog("Remove this item?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { target in
            Button("Remove", role: .destructive) { items.removeAll { $0.id == target.id } }
        }
        .sensoryFeedback(.selection, trigger: items.map(\.id))
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
    }
}

private struct ResumeItemCreation<Item, Editor: View>: View {
    @State var item: Item
    @ViewBuilder let editor: (Binding<Item>) -> Editor
    let save: (Item) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            editor($item).navigationTitle("New Item")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Add") { save(item); dismiss() } }
                }
        }.resumeSheet()
    }
}

struct ResumeEditorSheet: View {
    let api: SummaryAPIClient
    let onSave: (ResolvedResume) -> Void
    @State private var saved: ResolvedResume
    @State private var draft: ResumeDocument
    @State private var action = ResumeAction()
    @State private var showAvatarPicker = false
    @State private var showExportChoice = false
    @State private var showExport = false
    @State private var discard = false
    @Environment(\.dismiss) private var dismiss

    init(api: SummaryAPIClient, saved: ResolvedResume, onSave: @escaping (ResolvedResume) -> Void) {
        self.api = api
        self.onSave = onSave
        _saved = State(initialValue: saved)
        _draft = State(initialValue: saved.document)
    }

    private func contact(_ key: WritableKeyPath<ResumeDocument.Contact, String?>) -> Binding<String> {
        Binding(get: { draft.contact?[keyPath: key] ?? "" }, set: { value in
            var contact = draft.contact ?? .init()
            contact[keyPath: key] = value.isEmpty ? nil : value
            draft.contact = contact
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(saved.provenance).font(.footnote) } header: {
                    Text(saved.variantId == nil ? "Base résumé" : "This company · \(saved.companyName)")
                }
                Section("Candidate") {
                    TextField("Name", text: $draft.candidateName)
                    TextField("Headline", text: $draft.headline.text).accessibilityIdentifier("resume-headline")
                    TextField("Email", text: contact(\.email))
                    TextField("Phone", text: contact(\.phone))
                    TextField("Location", text: contact(\.location))
                }
                ResumeItemsEditor(label: "Links", items: $draft.links, newItem: { .init() }, name: { $0.label.nilIfBlank ?? "Link" }) { link in
                    Form { TextField("Label", text: link.label); TextField("URL", text: link.url) }.formStyle(.grouped)
                }
                ResumeItemsEditor(label: "Sections", items: $draft.sections, newItem: { .init(kind: .custom, title: "") }, name: { $0.title.nilIfBlank ?? "Section" }) { section in
                    ResumeSectionEditor(section: section)
                }
                Section("Avatar") {
                    Button(draft.avatarAssetId == nil ? "Add Avatar…" : "Replace Avatar…") { showAvatarPicker = true }
                    if draft.avatarAssetId != nil { Button("Remove Avatar", role: .destructive) { draft.avatarAssetId = nil } }
                }
                Button("Export or Publish…") { if draft == saved.document { showExport = true } else { showExportChoice = true } }
            }
            .formStyle(.grouped).navigationTitle("Edit Résumé")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if saved.document == draft { dismiss() } else { discard = true } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(export: false) }.accessibilityIdentifier("resume-save").disabled(draft == saved.document || draft.candidateName.nilIfBlank == nil) }
            }
            .fileImporter(isPresented: $showAvatarPicker, allowedContentTypes: [.jpeg, .png]) { result in
                switch result {
                case .success(let url): upload(url)
                case .failure(let error): action.error = error.localizedDescription
                }
            }
            .confirmationDialog("Export this résumé", isPresented: $showExportChoice) {
                Button("Save and Preview Draft") { save(export: true) }
                Button("Preview Displayed Saved Revision") { showExport = true }
            }
            .confirmationDialog("Discard unsaved edits?", isPresented: $discard) { Button("Discard", role: .destructive) { dismiss() } }
            .sheet(isPresented: $showExport) { ResumeExportSheet(api: api, initial: saved) }
        }.resumeSheet().resumeFeedback(action)
        .interactiveDismissDisabled(draft != saved.document || action.status != nil)
    }

    private func save(export: Bool) {
        action.run("Saving changes…") {
            let changes = try draft.edits(from: saved.document)
            if !changes.isEmpty {
                let fresh = try await api.editResume(target: saved.target, operations: changes, idempotencyKey: action.key(for: draft))
                saved = fresh
                draft = fresh.document
                onSave(fresh)
            }
            if export { showExport = true } else { dismiss() }
        }
    }

    private func upload(_ url: URL) {
        action.run("Preparing avatar…") {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let bytes = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            draft.avatarAssetId = try await api.uploadResumeAvatar(id: saved.familyId, data: bytes, filename: url.lastPathComponent, mimeType: mime) { sent, total in
                Task { @MainActor in
                    guard action.status != nil, total > 0 else { return }
                    action.status = "Uploading avatar · \(sent * 100 / total)% · \(sent) / \(total) bytes"
                }
            }
        }
    }
}

private struct ResumeSectionEditor: View {
    @Binding var section: ResumeDocument.Section
    var body: some View {
        Form {
            TextField("Section title", text: $section.title)
            Picker("Section type", selection: $section.kind) {
                ForEach(ResumeDocument.SectionKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            ResumeItemsEditor(label: "Entries", items: $section.entries, newItem: { .init() }, name: { $0.title ?? $0.organization ?? $0.description ?? "Entry" }) { entry in
                ResumeEntryEditor(entry: entry)
            }
        }.formStyle(.grouped)
    }
}

private struct ResumeEntryEditor: View {
    @Binding var entry: ResumeDocument.Entry
    var body: some View {
        Form {
            TextField("Title", text: $entry.title.text)
            TextField("Organization", text: $entry.organization.text)
            TextField("Location", text: $entry.location.text)
            TextField("Description", text: $entry.description.text, axis: .vertical)
            TextField("URL", text: $entry.url.text)
            Section {
                TextField("Start date", text: $entry.startDate.text)
                Toggle("Current", isOn: Binding(get: { entry.current ?? false }, set: { entry.current = $0 }))
                if entry.current != true { TextField("End date", text: $entry.endDate.text) }
            } footer: { Text("Use YYYY, YYYY-MM or YYYY-MM-DD.") }
            ResumeItemsEditor(label: "Bullets", items: $entry.bullets, newItem: { .init() }, name: { $0.text.nilIfBlank ?? "Bullet" }) { bullet in
                Form { TextField("Bullet", text: bullet.text, axis: .vertical) }.formStyle(.grouped)
            }
        }.formStyle(.grouped)
    }
}
