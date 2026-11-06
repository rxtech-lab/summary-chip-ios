#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

/// The owner picks the link to share: the summary's own `/s/<slug>` link (which only opens for
/// others while the summary is public) or a share link they made, then shares it as a link, image
/// or copy. The default link's visibility is edited in place; Manage Links edits, adds and deletes
/// links. Use inside a `List` in a navigation stack.
public struct ShareLinkSections: View {
    let api: SummaryAPIClient
    let summary: Summary
    let actionInToolbar: Bool
    /// The summary after its visibility or lifetime was saved from here.
    let onSummaryUpdated: (Summary) -> Void

    @State private var links: [SummaryShareLink] = []
    @State private var selectedLinkID: String?
    @State private var loaded = false
    @State private var loadError: String?
    @State private var editingSharing = false
    @State private var sharingSavedCount = 0

    public init(api: SummaryAPIClient, summary: Summary, actionInToolbar: Bool = false, onSummaryUpdated: @escaping (Summary) -> Void = { _ in }) {
        self.api = api
        self.summary = summary
        self.actionInToolbar = actionInToolbar
        self.onSummaryUpdated = onSummaryUpdated
    }

    /// Picker tag of the summary's own link; share link ids are UUIDs, so it never collides.
    private static let defaultLinkID = "default"

    private var liveLinks: [SummaryShareLink] { links.filter { !$0.isExpired } }
    private var selectedLink: SummaryShareLink? { liveLinks.first { $0.id == selectedLinkID } }
    private var isDefaultSelected: Bool { selectedLinkID == Self.defaultLinkID }
    /// The summary's own link opens for others only while it's public and hasn't expired.
    private var defaultLinkWorks: Bool {
        summary.visibility == .public && !(summary.expiresAt.map { $0 <= .now } ?? false)
    }
    private var canShare: Bool { selectedLink != nil || (isDefaultSelected && defaultLinkWorks) }

    /// The summary as shared: with the chosen link's URL.
    private var shared: Summary {
        var copy = summary
        if let selectedLink { copy.shareUrl = selectedLink.url }
        return copy
    }

    public var body: some View {
        Section {
            if !loaded {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Button(String(localized: "Try Again", bundle: .module)) { Task { await load() } }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading links…", bundle: .module).foregroundStyle(.secondary)
                    }
                }
            } else {
                #if os(macOS)
                linkPicker
                macLinkStatus
                NavigationLink {
                    ShareLinksView(api: api, summaryID: summary.id, links: $links)
                } label: {
                    Text("Manage Links", bundle: .module)
                }
                .accessibilityIdentifier("manage-share-links")
                #else
                linkPicker
                #endif
            }
            #if !os(macOS)
            if loaded {
                if isDefaultSelected {
                    Button { editingSharing = true } label: {
                        DefaultLinkRow(summary: summary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("edit-default-link-sharing")
                }
                NavigationLink {
                    ShareLinksView(api: api, summaryID: summary.id, links: $links)
                } label: {
                    Label(String(localized: "Manage Links", bundle: .module), systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("manage-share-links")
            }
            #endif
        } header: {
            // The section's one stable view hosts the sheet and the loading: modifiers on a group or
            // section of list rows are applied to every row, which presents the sheet more than once
            // (dismissing the share sheet), and a row is torn down when the create button is replaced.
            Text("Link to share", bundle: .module)
                .task { await load() }
                .onChange(of: links) { keepSelection() }
                .sheet(isPresented: $editingSharing) {
                    EditSharingSheet(api: api, summary: summary) { updated in
                        onSummaryUpdated(updated)
                        sharingSavedCount += 1
                    }
                }
                .sensoryFeedback(.success, trigger: sharingSavedCount)
        } footer: {
            footer
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        #if os(macOS)
        // Sending comes straight after picking the link; publishing is a separate, wider decision.
        ShareActionsSection(summary: shared, actionInToolbar: actionInToolbar, showsPrivateNote: false, canShare: canShare)
        publishSection
        #else
        publishSection
        ShareActionsSection(summary: shared, actionInToolbar: actionInToolbar, showsPrivateNote: false, canShare: canShare)
        #endif
    }

    private var linkPicker: some View {
        Picker(selection: $selectedLinkID) {
            Text(summary.visibility == .private
                ? String(localized: "Default link (private)", bundle: .module)
                : String(localized: "Default link", bundle: .module))
                .tag(Optional(Self.defaultLinkID))
            ForEach(liveLinks) { link in
                Text(link.displayName).tag(Optional(link.id))
            }
        } label: {
            Label(String(localized: "Link", bundle: .module), systemImage: "link")
        }
        .pickerStyle(.menu)
        .sensoryFeedback(.selection, trigger: selectedLinkID)
        .accessibilityIdentifier("share-link-picker")
    }

    private var publishSection: some View {
        Section {
            NavigationLink {
                MarketplacePublishingSheet(api: api, summaryID: summary.id, embedded: true)
                    .onDisappear {
                        Task { if let updated = try? await api.summary(id: summary.id) { onSummaryUpdated(updated) } }
                    }
            } label: {
                #if os(macOS)
                HStack(spacing: 12) {
                    ShareLinkIcon(systemImage: "globe", tint: .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Publish to Discover", bundle: .module)
                        Text("Share your content with the Chippy community in Discover.", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #else
                Label("Publish to Discover…", systemImage: "globe")
                #endif
            }
        }
    }

    #if os(macOS)
    /// Who can open the chosen link, when it expires, and its address, all in one row.
    @ViewBuilder
    private var macLinkStatus: some View {
        if let selectedLink {
            ShareLinkStatusRow(
                systemImage: selectedLink.access.systemImage,
                tint: selectedLink.access == .invited ? .indigo : .blue,
                title: selectedLink.access == .invited
                    ? String(localized: "Opens for \(selectedLink.emails.count) invited people.", bundle: .module)
                    : String(localized: "Opens for anyone with the link.", bundle: .module),
                expiresAt: selectedLink.expiresAt,
                showsExpiry: true,
                url: selectedLink.url
            ) { EmptyView() }
        } else if isDefaultSelected {
            ShareLinkStatusRow(
                systemImage: summary.visibility.systemImage,
                tint: summary.visibility.tint,
                title: summary.visibility == .public
                    ? String(localized: "Opens for anyone with the link.", bundle: .module)
                    : String(localized: "Only you can open it", bundle: .module),
                expiresAt: summary.expiresAt,
                showsExpiry: summary.visibility == .public,
                url: summary.shareUrl
            ) {
                Button(String(localized: "Edit sharing", bundle: .module)) { editingSharing = true }
                    .accessibilityIdentifier("edit-default-link-sharing")
            }
        }
    }
    #endif

    @ViewBuilder
    private var footer: some View {
        #if os(macOS)
        // The status row covers the rest; only the private default link needs explaining.
        if isDefaultSelected, summary.visibility == .private {
            Text("This summary is private, so its default link only opens for you. Make it public above, or create a link to share it.", bundle: .module)
        }
        #else
        if let selectedLink {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedLink.access == .invited
                        ? String(localized: "Opens for \(selectedLink.emails.count) invited people.", bundle: .module)
                        : String(localized: "Opens for anyone with the link.", bundle: .module))
                    ExpiryLabel(selectedLink.expiresAt)
                }
                Text(selectedLink.url.absoluteString).textSelection(.enabled)
            }
        } else if isDefaultSelected {
            VStack(alignment: .leading, spacing: 4) {
                if summary.visibility == .private {
                    Text("This summary is private, so its default link only opens for you. Make it public above, or create a link to share it.", bundle: .module)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Opens for anyone with the link.", bundle: .module)
                        ExpiryLabel(summary.expiresAt)
                    }
                }
                Text(summary.shareUrl.absoluteString).textSelection(.enabled)
            }
        }
        #endif
    }

    private func load() async {
        guard !loaded else { return }
        loadError = nil
        do {
            links = try await api.shareLinks(summaryID: summary.id)
            loaded = true
            keepSelection()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Keeps the chosen link while it's live; otherwise the newest live one, or the default link.
    private func keepSelection() {
        if selectedLink == nil, !isDefaultSelected { selectedLinkID = liveLinks.last?.id ?? Self.defaultLinkID }
    }
}

/// The summary's own link and who can open it; opens the Edit Sharing sheet.
private struct DefaultLinkRow: View {
    let summary: Summary

    var body: some View {
        HStack(spacing: 12) {
            ShareLinkIcon(systemImage: summary.visibility.systemImage, tint: summary.visibility.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Default link", bundle: .module)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if summary.visibility == .public {
                    ExpiryLabel(summary.expiresAt)
                } else {
                    Text("Only you can open it", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(summary.visibility.title).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Edit sharing", bundle: .module))
    }
}
#endif
