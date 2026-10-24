#if os(iOS) || os(macOS)
import SwiftUI

/// Where a list of share links is saved: a summary's links (which may be invite-only) or a podcast
/// episode's (always open to anyone holding them, since its web player is signed out).
public struct ShareLinkStore: Sendable {
    public enum Subject: Sendable { case summary, podcast }

    public var subject: Subject
    var create: @Sendable (ShareLinkChanges) async throws -> SummaryShareLink
    var update: @Sendable (_ linkID: String, ShareLinkChanges) async throws -> SummaryShareLink
    var delete: @Sendable (_ linkID: String) async throws -> Void

    public init(
        subject: Subject,
        create: @escaping @Sendable (ShareLinkChanges) async throws -> SummaryShareLink,
        update: @escaping @Sendable (_ linkID: String, ShareLinkChanges) async throws -> SummaryShareLink,
        delete: @escaping @Sendable (_ linkID: String) async throws -> Void
    ) {
        self.subject = subject
        self.create = create
        self.update = update
        self.delete = delete
    }

    var allowsInvites: Bool { subject == .summary }

    public static func summary(api: SummaryAPIClient, summaryID: String) -> ShareLinkStore {
        ShareLinkStore(subject: .summary) { changes in
            try await api.createShareLink(summaryID: summaryID, changes: changes)
        } update: { linkID, changes in
            try await api.updateShareLink(summaryID: summaryID, linkID: linkID, changes: changes)
        } delete: { linkID in
            try await api.deleteShareLink(summaryID: summaryID, linkID: linkID)
        }
    }

    public static func podcast(api: SummaryAPIClient, podcast: DailyPodcast) -> ShareLinkStore {
        ShareLinkStore(subject: .podcast) { changes in
            try await api.createPodcastShareLink(podcast, changes: changes)
        } update: { linkID, changes in
            try await api.updatePodcastShareLink(key: podcast.key, linkID: linkID, changes: changes)
        } delete: { linkID in
            try await api.deletePodcastShareLink(key: podcast.key, linkID: linkID)
        }
    }

    var emptyMessage: Text {
        switch subject {
        case .summary: Text("No links yet. Add one to share the summary, with its own expiry, or only with certain people.", bundle: .module)
        case .podcast: Text("No links yet. Add one to let anyone with it listen to this episode on the web and read its captions, with its own expiry.", bundle: .module)
        }
    }

    var listFooter: Text {
        switch subject {
        case .summary: Text("Anyone who opened the summary with a link loses access when you delete it or it expires.", bundle: .module)
        case .podcast: Text("A link stops playing the episode when you delete it or it expires. Your source chips keep their sharing settings.", bundle: .module)
        }
    }

    var deleteMessage: Text {
        switch subject {
        case .summary: Text("The link stops working, and everyone who opened the summary with it loses access.", bundle: .module)
        case .podcast: Text("The link stops working for everyone who has it.", bundle: .module)
        }
    }
}

/// A summary's or podcast's share links, each with its own lifetime and, for summaries, optionally
/// a list of invited emails. Pushed from the share sheet, or the root of a podcast's publish sheet.
public struct ShareLinksView: View {
    let store: ShareLinkStore
    @Binding var links: [SummaryShareLink]

    @State private var editor: EditorTarget?
    @State private var deleting: SummaryShareLink?
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var copiedID: String?
    @State private var deletedCount = 0
    @State private var savedCount = 0

    public init(api: SummaryAPIClient, summaryID: String, links: Binding<[SummaryShareLink]>) {
        self.init(store: .summary(api: api, summaryID: summaryID), links: links)
    }

    public init(store: ShareLinkStore, links: Binding<[SummaryShareLink]>) {
        self.store = store
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
                    store.emptyMessage
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    HStack(spacing: 12) {
                        Button { editor = .edit(link) } label: { ShareLinkRow(link: link) }
                            .buttonStyle(.plain)
                        Button { copy(link) } label: {
                            Label(String(localized: "Copy Link", bundle: .module), systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .disabled(link.isExpired)
                        .accessibilityIdentifier("copy-share-link")
                    }
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
            } footer: {
                store.listFooter
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(store.subject == .podcast
            ? Text("Publish Podcast", bundle: .module, comment: "Title of the screen managing a podcast episode's share links")
            : Text("Links", bundle: .module, comment: "Title of the screen managing a summary's share links"))
        .summaryInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = .create } label: {
                    Label(String(localized: "Add Link", bundle: .module), systemImage: "plus")
                }
                .disabled(links.count >= 20)
                .accessibilityIdentifier("add-share-link")
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case .create:
                ShareLinkEditorSheet(store: store, link: nil) { created in
                    links.append(created)
                    savedCount += 1
                } onDeleted: { _ in }
            case .edit(let link):
                ShareLinkEditorSheet(store: store, link: link) { updated in
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
            store.deleteMessage
        }
        .overlay {
            if let status { ActionStatusOverlay(status) }
        }
        .overlay(alignment: .bottom) {
            if copiedID != nil { LinkCopiedFeedback() }
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
            try await store.delete(link.id)
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

/// Clipboard feedback stays above the content without blocking the next action.
struct LinkCopiedFeedback: View {
    var body: some View {
        Label(String(localized: "Copied", bundle: .module), systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .padding()
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 20)
            .allowsHitTesting(false)
    }
}

/// One extra link: its name, who can open it, and when it expires.
struct ShareLinkRow: View {
    let link: SummaryShareLink

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
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Dedicated sheet to create or change one share link: its name, who can open it (anyone, or only
/// invited emails, for summaries), and its lifetime. Removing an email revokes that person's access on save.
public struct ShareLinkEditorSheet: View {
    let store: ShareLinkStore
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
    @State private var copied = false
    @FocusState private var emailFieldFocused: Bool

    public init(
        api: SummaryAPIClient, summaryID: String, link: SummaryShareLink?,
        onSaved: @escaping (SummaryShareLink) -> Void, onDeleted: @escaping (String) -> Void
    ) {
        self.init(store: .summary(api: api, summaryID: summaryID), link: link, onSaved: onSaved, onDeleted: onDeleted)
    }

    public init(
        store: ShareLinkStore, link: SummaryShareLink?,
        onSaved: @escaping (SummaryShareLink) -> Void, onDeleted: @escaping (String) -> Void
    ) {
        self.store = store
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
                if let link { clipboardSection(link) }
                Section {
                    TextField(String(localized: "Name", bundle: .module), text: $label, prompt: Text("Family, Team…", bundle: .module))
                        .accessibilityIdentifier("share-link-label")
                } header: {
                    Text("Name", bundle: .module)
                } footer: {
                    Text("Only you see the name.", bundle: .module)
                }

                if store.allowsInvites {
                    accessSection
                    if access == .invited { invitedSection }
                }

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                store.deleteMessage
            }
            .overlay {
                if let status { ActionStatusOverlay(status) }
            }
            .overlay(alignment: .bottom) {
                if copied { LinkCopiedFeedback() }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
            .sensoryFeedback(.success, trigger: copied) { _, new in new }
            .statusAlert(Text("Couldn't save the link", bundle: .module), message: errorMessage) { errorMessage = nil }
            .interactiveDismissDisabled(status != nil)
            .sensoryFeedback(.impact(weight: .light), trigger: addedCount)
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
        .summarySheetSize()
    }

    private func clipboardSection(_ link: SummaryShareLink) -> some View {
        Section {
            Text(link.url.absoluteString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                #if os(iOS)
                UIPasteboard.general.url = link.url
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                #endif
                copied = true
            } label: {
                Label(String(localized: "Copy Link", bundle: .module), systemImage: "doc.on.doc")
            }
            .disabled(link.isExpired)
            .accessibilityIdentifier("copy-edited-share-link")
        }
    }

    private var accessSection: some View {
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
                saved = try await store.update(link.id, changes)
            } else {
                let changes = ShareLinkChanges(label: trimmedLabel, access: access, ttl: ttl, emails: access == .invited ? emails : [])
                saved = try await store.create(changes)
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
            try await store.delete(link.id)
            onDeleted(link.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
