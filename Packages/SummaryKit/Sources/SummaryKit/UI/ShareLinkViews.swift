#if os(iOS) || os(macOS)
import SwiftUI

/// A summary's share links, each with its own lifetime and, optionally, a list of invited emails.
/// Summaries are shared only through links made here. Pushed from the share sheet.
public struct ShareLinksView: View {
    let api: SummaryAPIClient
    let summaryID: String
    @Binding var links: [SummaryShareLink]

    @State private var editor: EditorTarget?
    @State private var deleting: SummaryShareLink?
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var copiedID: String?
    @State private var deletedCount = 0
    @State private var savedCount = 0

    public init(api: SummaryAPIClient, summaryID: String, links: Binding<[SummaryShareLink]>) {
        self.api = api
        self.summaryID = summaryID
        self._links = links
    }

    enum EditorTarget: Identifiable {
        case create
        case edit(SummaryShareLink)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let link): link.id
            }
        }
    }

    public var body: some View {
        List {
            Section {
                if links.isEmpty {
                    Text("No links yet. Add one to share the summary, with its own expiry, or only with certain people.", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    Button { editor = .edit(link) } label: { ShareLinkRow(link: link, copied: copiedID == link.id) }
                        .tint(.primary)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = link } label: {
                                Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { copy(link) } label: {
                                Label(String(localized: "Copy Link", bundle: .module), systemImage: "doc.on.doc")
                            }
                            .tint(.accentColor)
                        }
                        .contextMenu {
                            Button { copy(link) } label: { Label(String(localized: "Copy Link", bundle: .module), systemImage: "doc.on.doc") }
                            Button { editor = .edit(link) } label: { Label(String(localized: "Edit Link", bundle: .module), systemImage: "slider.horizontal.3") }
                            Divider()
                            Button(role: .destructive) { deleting = link } label: { Label(String(localized: "Delete", bundle: .module), systemImage: "trash") }
                        }
                        .accessibilityIdentifier("share-link-row")
                }
                Button { editor = .create } label: {
                    Label(String(localized: "Add Link", bundle: .module), systemImage: "plus.circle.fill")
                }
                .disabled(links.count >= 20)
                .accessibilityIdentifier("add-share-link")
            } footer: {
                Text("Anyone who opened the summary with a link loses access when you delete it or it expires.", bundle: .module)
            }
        }
        .navigationTitle(Text("Links", bundle: .module, comment: "Title of the screen managing a summary's share links"))
        .summaryInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = .create } label: {
                    Label(String(localized: "Add Link", bundle: .module), systemImage: "plus")
                }
                .disabled(links.count >= 20)
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case .create:
                ShareLinkEditorSheet(api: api, summaryID: summaryID, link: nil) { created in
                    links.append(created)
                    savedCount += 1
                } onDeleted: { _ in }
            case .edit(let link):
                ShareLinkEditorSheet(api: api, summaryID: summaryID, link: link) { updated in
                    if let index = links.firstIndex(where: { $0.id == updated.id }) { links[index] = updated }
                    savedCount += 1
                } onDeleted: { id in
                    links.removeAll { $0.id == id }
                    deletedCount += 1
                }
            }
        }
        .confirmationDialog(
            Text("Delete this link?", bundle: .module),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { link in
            Button(String(localized: "Delete Link", bundle: .module), role: .destructive) {
                Task { await delete(link) }
            }
        } message: { _ in
            Text("The link stops working, and everyone who opened the summary with it loses access.", bundle: .module)
        }
        .overlay {
            if let status { ActionStatusOverlay(status) }
        }
        .statusAlert(Text("Couldn't delete the link", bundle: .module), message: errorMessage) { errorMessage = nil }
        .sensoryFeedback(.success, trigger: deletedCount)
        .sensoryFeedback(.success, trigger: savedCount)
        .sensoryFeedback(.success, trigger: copiedID) { _, new in new != nil }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
    }

    private func copy(_ link: SummaryShareLink) {
        #if os(iOS)
        UIPasteboard.general.url = link.url
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
        #endif
        copiedID = link.id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedID == link.id { copiedID = nil }
        }
    }

    private func delete(_ link: SummaryShareLink) async {
        status = String(localized: "Deleting link…", bundle: .module)
        defer { status = nil }
        do {
            try await api.deleteShareLink(summaryID: summaryID, linkID: link.id)
            links.removeAll { $0.id == link.id }
            deletedCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ShareLinkIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// One extra link: its name, who can open it, and when it expires.
struct ShareLinkRow: View {
    let link: SummaryShareLink
    var copied = false

    var body: some View {
        HStack(spacing: 12) {
            ShareLinkIcon(systemImage: link.access.systemImage, tint: link.isExpired ? .gray : (link.access == .invited ? .indigo : .blue))
            VStack(alignment: .leading, spacing: 3) {
                Text(link.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if link.access == .invited {
                        HStack(spacing: 4) {
                            Image(systemName: "envelope")
                            Text("\(link.emails.count) invited", bundle: .module)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ExpiryLabel(link.expiresAt)
                }
            }
            Spacer(minLength: 0)
            if copied {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(Text("Copied", bundle: .module))
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Dedicated sheet to create or change one share link: its name, who can open it (anyone, or only
/// invited emails), and its lifetime. Removing an email revokes that person's access on save.
public struct ShareLinkEditorSheet: View {
    let api: SummaryAPIClient
    let summaryID: String
    let link: SummaryShareLink?
    let onSaved: (SummaryShareLink) -> Void
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var access: ShareLinkAccess
    @State private var ttl: TTLOption
    @State private var emails: [String]
    @State private var newEmail = ""
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var confirmsDelete = false
    @State private var addedCount = 0
    @FocusState private var emailFieldFocused: Bool

    public init(
        api: SummaryAPIClient, summaryID: String, link: SummaryShareLink?,
        onSaved: @escaping (SummaryShareLink) -> Void, onDeleted: @escaping (String) -> Void
    ) {
        self.api = api
        self.summaryID = summaryID
        self.link = link
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        self._label = State(initialValue: link?.label ?? "")
        self._access = State(initialValue: link?.access ?? .anyone)
        self._ttl = State(initialValue: link.map { TTLOption(ttlDays: $0.ttlDays) } ?? .default)
        self._emails = State(initialValue: link?.emails.map(\.email) ?? [])
    }

    private var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ttlChanged: Bool { link.map { ttl != TTLOption(ttlDays: $0.ttlDays) } ?? true }
    private var emailsChanged: Bool { link.map { emails != $0.emails.map(\.email) } ?? true }
    private var hasChanges: Bool {
        guard let link else { return true }
        return trimmedLabel != (link.label ?? "") || access != link.access || ttlChanged || emailsChanged
    }
    private var pendingEmail: String? { EmailAddress.normalized(newEmail) }
    private var canSave: Bool { hasChanges && (access == .anyone || !emails.isEmpty) && status == nil }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name", bundle: .module), text: $label, prompt: Text("Family, Team…", bundle: .module))
                        .accessibilityIdentifier("share-link-label")
                } header: {
                    Text("Name", bundle: .module)
                } footer: {
                    Text("Only you see the name.", bundle: .module)
                }

                Section {
                    ForEach(ShareLinkAccess.allCases) { value in
                        Button { access = value } label: {
                            HStack(spacing: 12) {
                                ShareLinkIcon(systemImage: value.systemImage, tint: value == .invited ? .indigo : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(value.title).foregroundStyle(.primary)
                                    Text(value.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if access == value {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(access == value ? .isSelected : [])
                        .sensoryFeedback(.selection, trigger: access == value) { _, new in new }
                    }
                } header: {
                    Text("Who can open it", bundle: .module)
                }

                if access == .invited { invitedSection }

                Section {
                    Picker(selection: $ttl) {
                        ForEach(TTLOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    } label: {
                        Label(String(localized: "Expires after", bundle: .module), systemImage: "hourglass")
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    #else
                    .pickerStyle(.navigationLink)
                    #endif
                } header: {
                    Text("Link expiry", bundle: .module)
                } footer: {
                    expiryFooter
                }

                if link != nil {
                    Section {
                        Button(role: .destructive) { confirmsDelete = true } label: {
                            Label(String(localized: "Delete Link", bundle: .module), systemImage: "trash")
                        }
                        .accessibilityIdentifier("delete-share-link")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(link == nil ? Text("New Link", bundle: .module) : Text("Edit Link", bundle: .module))
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(link == nil ? String(localized: "Create", bundle: .module) : String(localized: "Save", bundle: .module)) {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .accessibilityIdentifier("save-share-link")
                }
            }
            .confirmationDialog(Text("Delete this link?", bundle: .module), isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button(String(localized: "Delete Link", bundle: .module), role: .destructive) { Task { await delete() } }
            } message: {
                Text("The link stops working, and everyone who opened the summary with it loses access.", bundle: .module)
            }
            .overlay {
                if let status { ActionStatusOverlay(status) }
            }
            .statusAlert(Text("Couldn't save the link", bundle: .module), message: errorMessage) { errorMessage = nil }
            .interactiveDismissDisabled(status != nil)
            .sensoryFeedback(.impact(weight: .light), trigger: addedCount)
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
        .summarySheetSize()
    }

    private var invitedSection: some View {
        Section {
            ForEach(emails, id: \.self) { email in
                HStack {
                    Label(email, systemImage: "person.crop.circle")
                    Spacer()
                    #if os(macOS)
                    Button { revoke(email) } label: {
                        Label(String(localized: "Revoke", bundle: .module), systemImage: "minus.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help(String(localized: "Revoke", bundle: .module))
                    #endif
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { revoke(email) } label: {
                        Label(String(localized: "Revoke", bundle: .module), systemImage: "person.crop.circle.badge.minus")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { revoke(email) } label: {
                        Label(String(localized: "Revoke", bundle: .module), systemImage: "person.crop.circle.badge.minus")
                    }
                }
            }
            HStack {
                TextField(String(localized: "Add email", bundle: .module), text: $newEmail, prompt: Text("name@example.com", bundle: .module))
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($emailFieldFocused)
                    .onSubmit(addEmail)
                    .accessibilityIdentifier("share-link-email")
                Button(String(localized: "Add", bundle: .module), action: addEmail)
                    .disabled(pendingEmail == nil || emails.count >= 50)
            }
        } header: {
            Text("Invited people (\(emails.count))", bundle: .module)
        } footer: {
            Text("They open the link signed in to Chippy with one of these addresses. Revoking an address ends that person's access when you save.", bundle: .module)
        }
    }

    @ViewBuilder
    private var expiryFooter: some View {
        if let link, !ttlChanged {
            if link.isExpired {
                Text("This link has expired. Pick a new expiry to reopen it.", bundle: .module)
            } else if let expiresAt = link.expiresAt {
                Text("Stops working on \(expiresAt.formatted(date: .abbreviated, time: .shortened)).", bundle: .module)
            } else {
                Text("The link stays open until you delete it.", bundle: .module)
            }
        } else if ttl == .never {
            Text("The link stays open until you delete it.", bundle: .module)
        } else {
            Text("The link stops working \(ttl.title) from now.", bundle: .module)
        }
    }

    private func addEmail() {
        guard let email = pendingEmail else { return }
        if !emails.contains(email) {
            emails.append(email)
            addedCount += 1
        }
        newEmail = ""
        emailFieldFocused = true
    }

    private func revoke(_ email: String) {
        emails.removeAll { $0 == email }
    }

    private func save() async {
        // An address still typed in the field counts, so it isn't lost on save.
        if access == .invited, pendingEmail != nil { addEmail() }
        status = link == nil ? String(localized: "Creating link…", bundle: .module) : String(localized: "Saving link…", bundle: .module)
        defer { status = nil }
        do {
            let saved: SummaryShareLink
            if let link {
                let changes = ShareLinkChanges(
                    label: trimmedLabel != (link.label ?? "") ? trimmedLabel : nil,
                    access: access != link.access ? access : nil,
                    ttl: ttlChanged ? ttl : nil,
                    emails: emailsChanged ? emails : nil
                )
                saved = try await api.updateShareLink(summaryID: summaryID, linkID: link.id, changes: changes)
            } else {
                let changes = ShareLinkChanges(label: trimmedLabel, access: access, ttl: ttl, emails: access == .invited ? emails : [])
                saved = try await api.createShareLink(summaryID: summaryID, changes: changes)
            }
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        guard let link else { return }
        status = String(localized: "Deleting link…", bundle: .module)
        defer { status = nil }
        do {
            try await api.deleteShareLink(summaryID: summaryID, linkID: link.id)
            onDeleted(link.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
