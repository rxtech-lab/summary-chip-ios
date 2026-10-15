import AuthenticationServices
import SummaryKit
import SwiftUI

enum MiniManagementSection: String, Identifiable {
    case data, connections, sharing
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct MiniAppManagementSheet: View {
    let api: SummaryAPIClient
    let app: MiniApp
    let section: MiniManagementSection
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .data:
                    List(app.document.tables.keys.sorted(), id: \.self) { table in
                        NavigationLink { MiniRecordList(api: api, app: app, table: table) } label: {
                            Label(table, systemImage: app.document.tables[table]?["scope"]?.stringValue == "shared" ? "person.2" : "person")
                        }
                    }
                case .connections: MiniConnections(api: api, app: app)
                case .sharing: MiniMembers(api: api, app: app)
                }
            }
            .navigationTitle(section.title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }.summarySheetSize()
    }
}

private struct MiniRecordList: View {
    let api: SummaryAPIClient
    let app: MiniApp
    let table: String
    @State private var rows: [MiniAppRecord] = []
    @State private var cursor: String?
    @State private var error: String?
    @State private var editing: MiniAppRecord?
    @State private var showsEditor = false
    var body: some View {
        List {
            ForEach(rows) { row in
                Button { editing = row; showsEditor = true } label: {
                    VStack(alignment: .leading) {
                        Text(row.data.keys.sorted().compactMap { row.data[$0]?.miniText }.prefix(3).joined(separator: " · ")).lineLimit(3)
                        Text("Revision \(row.revision)").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if cursor != nil { Button("Load More") { Task { await load(more: true) } } }
        }
        .navigationTitle(table)
        .overlay { if rows.isEmpty { ContentUnavailableView("No Records", systemImage: "tablecells") } }
        .task { await load() }
        .refreshable { await load() }
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add Record", systemImage: "plus") { editing = nil; showsEditor = true } } }
        .sheet(isPresented: $showsEditor) { MiniRecordEditor(api: api, app: app, table: table, record: editing) { Task { await load() } } }
        .statusAlert("Data", message: error) { error = nil }
    }
    private func load(more: Bool = false) async {
        do { let page = try await api.miniAppRecords(id: app.id, table: table, cursor: more ? cursor : nil); rows = more ? rows + page.items : page.items; cursor = page.nextCursor }
        catch { self.error = error.localizedDescription }
    }
}

private struct MiniRecordEditor: View {
    let api: SummaryAPIClient
    let app: MiniApp
    let table: String
    let record: MiniAppRecord?
    let onSaved: () -> Void
    @State private var values: [String: JSONValue]
    @State private var error: String?
    @State private var busy = false
    @State private var confirmsDelete = false
    @Environment(\.dismiss) private var dismiss
    init(api: SummaryAPIClient, app: MiniApp, table: String, record: MiniAppRecord?, onSaved: @escaping () -> Void) {
        self.api = api; self.app = app; self.table = table; self.record = record; self.onSaved = onSaved
        _values = State(initialValue: record?.data ?? [:])
    }
    private var fields: [String: JSONValue] { app.document.tables[table]?["fields"]?.miniObject ?? [:] }
    var body: some View {
        NavigationStack {
            Form {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    if fields[key]?["type"]?.stringValue == "boolean" {
                        Toggle(key, isOn: Binding(get: { values[key]?.miniTruth ?? false }, set: { values[key] = .bool($0) }))
                    } else {
                        TextField(key, text: Binding(get: { values[key]?.miniText ?? "" }, set: { values[key] = .string($0) }))
                    }
                }
                if record != nil { Button("Delete Record", systemImage: "trash", role: .destructive) { confirmsDelete = true } }
            }
            .formStyle(.grouped)
            .navigationTitle(record == nil ? "Add Record" : "Edit Record")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy) }
            }
            .confirmationDialog("Delete this record?", isPresented: $confirmsDelete) { Button("Delete", role: .destructive) { Task { await save(remove: true) } } }
            .statusAlert("Record", message: error) { error = nil }
        }.summarySheetSize()
    }
    private func save(remove: Bool = false) async {
        busy = true; defer { busy = false }
        do {
            var data = values
            for (key, field) in fields {
                if field["type"]?.stringValue == "number", let text = values[key]?.stringValue { data[key] = Double(text).map(JSONValue.number) ?? .null }
                if field["type"]?.stringValue == "json", let text = values[key]?.stringValue { data[key] = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
                if field["type"]?.stringValue == "boolean", data[key] == nil { data[key] = .bool(false) }
            }
            var body: [String: JSONValue] = ["table": .string(table), "operation": .string(remove ? "delete" : record == nil ? "create" : "update"), "data": .object(data)]
            if let record { body["id"] = .string(record.id); body["revision"] = .number(Double(record.revision)) }
            _ = try await api.miniAppRequest(id: app.id, resource: "records", method: "POST", body: .object(body))
            onSaved(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct MiniMembers: View {
    let api: SummaryAPIClient
    let app: MiniApp
    @State private var members: [JSONValue] = []
    @State private var previewLink: SummaryShareLink?
    @State private var linkBusy = false
    @State private var error: String?
    @State private var editor = false
    @State private var selected: JSONValue?
    var body: some View {
        List {
            Section {
                if let previewLink {
                    ShareLink("Share App Preview", item: previewLink.url)
                    Button("Disable Preview Link", role: .destructive) { Task { await removeLink() } }
                } else {
                    Button("Create Preview Link", systemImage: "link.badge.plus") { Task { await createLink() } }.disabled(linkBusy)
                }
                Text("A preview link shows the app's title and description to anyone holding the link.").foregroundStyle(.secondary)
                Text("Only invited people can run this app. Each person's personal tables stay private.").foregroundStyle(.secondary)
            }
            ForEach(members, id: \.self) { member in
                Button(member["email"]?.miniText ?? "Member") { selected = member; editor = true }
            }
        }
        .task { await load() }
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add Member", systemImage: "person.badge.plus") { selected = nil; editor = true } } }
        .sheet(isPresented: $editor) { MiniMemberEditor(api: api, app: app, member: selected) { Task { await load() } } }
        .statusAlert("Sharing", message: error) { error = nil }
    }
    private func load() async {
        do {
            members = try await api.miniAppRequest(id: app.id, resource: "members")["items"]?.miniArray ?? []
            previewLink = try await api.shareLinks(summaryID: app.id).first { ($0.label == "Clip Preview" || $0.label == "Mini App Preview") && !$0.isExpired }
        }
        catch { self.error = error.localizedDescription }
    }
    private func createLink() async {
        linkBusy = true; defer { linkBusy = false }
        do { previewLink = try await api.createShareLink(summaryID: app.id, changes: ShareLinkChanges(label: "Clip Preview", access: .anyone)) }
        catch { self.error = error.localizedDescription }
    }
    private func removeLink() async {
        guard let previewLink else { return }
        do { try await api.deleteShareLink(summaryID: app.id, linkID: previewLink.id); self.previewLink = nil }
        catch { self.error = error.localizedDescription }
    }

}

private struct MiniMemberEditor: View {
    let api: SummaryAPIClient
    let app: MiniApp
    let member: JSONValue?
    let onSaved: () -> Void
    @State private var email: String
    @State private var permissions: [String: JSONValue]
    @State private var error: String?
    @State private var confirmsRemoval = false
    @Environment(\.dismiss) private var dismiss
    init(api: SummaryAPIClient, app: MiniApp, member: JSONValue?, onSaved: @escaping () -> Void) {
        self.api = api; self.app = app; self.member = member; self.onSaved = onSaved
        _email = State(initialValue: member?["email"]?.miniText ?? "")
        _permissions = State(initialValue: member?["permissions"]?.miniObject ?? [:])
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Email", text: $email).disabled(member != nil)
                ForEach(app.document.tables.keys.sorted().filter { app.document.tables[$0]?["scope"]?.stringValue == "shared" }, id: \.self) { table in
                    Picker(table, selection: Binding(get: { permissions[table]?.stringValue ?? "none" }, set: { permissions[table] = $0 == "none" ? nil : .string($0) })) {
                        Text("No Access").tag("none"); Text("Read").tag("read"); Text("Read and Write").tag("write")
                    }
                }
                if member != nil { Button("Remove Member", role: .destructive) { confirmsRemoval = true } }
            }
            .formStyle(.grouped)
            .navigationTitle(member == nil ? "Add Member" : "Member Access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(email.isEmpty) }
            }
            .confirmationDialog("Remove this member?", isPresented: $confirmsRemoval) { Button("Remove", role: .destructive) { Task { await save(remove: true) } } }
            .statusAlert("Member", message: error) { error = nil }
        }.summarySheetSize()
    }
    private func save(remove: Bool = false) async {
        do {
            _ = try await api.miniAppRequest(id: app.id, resource: "members", method: "PUT", body: .object(["email": .string(email), "permissions": .object(permissions), "remove": .bool(remove)]))
            onSaved(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
