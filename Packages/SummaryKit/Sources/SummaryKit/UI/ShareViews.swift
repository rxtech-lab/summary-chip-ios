#if os(iOS) || os(macOS)
import LinkPresentation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)

/// `UIActivityViewController` for SwiftUI sheets (works inside app extensions too).
public struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    public init(items: [Any], onComplete: @escaping (Bool) -> Void = { _ in }) {
        self.items = items
        self.onComplete = onComplete
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Presents a `UIActivityViewController` straight from UIKit, on top of whatever the anchor's
/// window currently shows. A SwiftUI `.sheet` hung off `List` rows gets torn down when the row
/// re-renders (e.g. the image spinner toggling), which closed the share sheet right away.
@MainActor
final class ActivityPresenter {
    weak var anchor: UIView?

    func present(_ items: [Any]) {
        guard let anchor, var top = anchor.window?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = anchor
        controller.popoverPresentationController?.sourceRect = anchor.bounds
        top.present(controller, animated: true)
    }
}

private struct ActivityPresenterAnchor: UIViewRepresentable {
    let presenter: ActivityPresenter

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        presenter.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { presenter.anchor = view }
}

#else
@MainActor
final class ActivityPresenter {
    weak var anchor: NSView?
    private var picker: NSSharingServicePicker?

    func present(_ items: [Any]) {
        guard let anchor, anchor.window != nil else { return }
        let picker = NSSharingServicePicker(items: items)
        self.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
}

private struct ActivityPresenterAnchor: NSViewRepresentable {
    let presenter: ActivityPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { presenter.anchor = view }
}
#endif

/// Pending share, presented as a sheet.
public struct ShareRequest: Identifiable {
    public let id = UUID()
    public let items: [Any]
    public init(items: [Any]) { self.items = items }
}

public enum ShareMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case link
    case image
    case copy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: String(localized: "Everything", bundle: .module, comment: "Share mode: link, image and full text")
        case .link: String(localized: "Link", bundle: .module, comment: "Share mode: send only the link (noun)")
        case .image: String(localized: "Image", bundle: .module, comment: "Share mode: send the preview image")
        case .copy: String(localized: "Copy link", bundle: .module)
        }
    }

    public var detail: String {
        switch self {
        case .system: String(localized: "Link preview, image and the full summary. Each app takes what it supports.", bundle: .module)
        case .link: String(localized: "Messages, Slack and others render the preview card from the link.", bundle: .module)
        case .image: String(localized: "Sends the preview image with the title and link as a caption.", bundle: .module)
        case .copy: String(localized: "Copies the link to the clipboard.", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .system: "square.and.arrow.up.on.square"
        case .link: "link"
        case .image: "photo"
        case .copy: "doc.on.doc"
        }
    }

    var actionTitle: String {
        switch self {
        case .copy: String(localized: "Copy link", bundle: .module)
        default: String(localized: "Share", bundle: .module, comment: "Button: open the share sheet")
        }
    }
}

public enum ShareCaption {
    /// Caption sent next to the image: the title and the link.
    public static func text(for summary: Summary) -> String {
        "\(summary.title)\n\(summary.shareUrl.absoluteString)"
    }

    /// The whole summary as plain text, for apps that take text (Mail, Notes, …).
    public static func fullText(for summary: Summary) -> String {
        var parts = [summary.title, summary.summary]
        if !summary.highlights.isEmpty {
            parts.append(summary.highlights.map { "• \($0)" }.joined(separator: "\n"))
        }
        parts.append(summary.shareUrl.absoluteString)
        return parts.joined(separator: "\n\n")
    }
}

/// Activity items for the "Everything" mode. Every app gets the link with rich metadata; apps that
/// take text or images also get the full summary and the preview image. Messages and the
/// clipboard only get the link, since they build their own preview card from it.
#if os(iOS)
enum RichShareItems {
    static func make(for summary: Summary, imageFile: URL?) -> [Any] {
        var items: [Any] = [LinkItemSource(summary: summary, imageFile: imageFile)]
        items.append(TextItemSource(summary: summary))
        if let imageFile { items.append(ImageItemSource(file: imageFile)) }
        return items
    }

    /// Activities that should receive only the link.
    static let linkOnly: Set<UIActivity.ActivityType> = [.message, .copyToPasteboard, .addToReadingList]

    final class LinkItemSource: NSObject, UIActivityItemSource {
        let summary: Summary
        let imageFile: URL?

        init(summary: Summary, imageFile: URL?) {
            self.summary = summary
            self.imageFile = imageFile
        }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { summary.shareUrl }

        func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
            // Mail and text-taking apps already get the link inside the full text.
            if let type, TextItemSource.textActivities.contains(type) { return nil }
            return summary.shareUrl
        }

        func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
            summary.title
        }

        func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
            let metadata = LPLinkMetadata()
            metadata.originalURL = summary.shareUrl
            metadata.url = summary.shareUrl
            metadata.title = summary.title
            if let imageFile, let provider = NSItemProvider(contentsOf: imageFile) {
                metadata.imageProvider = provider
                metadata.iconProvider = provider
            }
            return metadata
        }
    }

    final class TextItemSource: NSObject, UIActivityItemSource {
        /// System activities where the full text replaces the bare link.
        static let textActivities: Set<UIActivity.ActivityType> = [.mail, .print, .init("com.apple.mobilenotes.SharingExtension")]

        let summary: Summary

        init(summary: Summary) { self.summary = summary }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { "" }

        func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
            if let type, linkOnly.contains(type) || type == .saveToCameraRoll || type == .airDrop { return nil }
            if let type, Self.textActivities.contains(type) { return ShareCaption.fullText(for: summary) }
            // Third-party apps get the link item too, so leave the URL out of the text.
            var parts = [summary.title, summary.summary]
            if !summary.highlights.isEmpty {
                parts.append(summary.highlights.map { "• \($0)" }.joined(separator: "\n"))
            }
            return parts.joined(separator: "\n\n")
        }

        func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
            summary.title
        }
    }

    final class ImageItemSource: NSObject, UIActivityItemSource {
        let file: URL

        init(file: URL) { self.file = file }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { file }

        func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
            if let type, linkOnly.contains(type) { return nil }
            return file
        }
    }
}

#else
enum RichShareItems {
    static func make(for summary: Summary, imageFile: URL?) -> [Any] {
        var items: [Any] = [summary.shareUrl, ShareCaption.fullText(for: summary)]
        if let imageFile { items.append(imageFile) }
        return items
    }
}
#endif

/// Share mode picker plus a single share button. Reused by the share sheet, the new-summary
/// result screen and the share extension's result screen.
public struct ShareActionsSection: View {
    let summary: Summary
    /// Puts the share button in the enclosing toolbar instead of a row below the picker.
    let actionInToolbar: Bool
    /// Notes below the picker that a private summary's link only opens for its owner.
    let showsPrivateNote: Bool

    @Environment(\.summaryAssetLoader) private var loader
    @AppStorage("shareMode") private var mode: ShareMode = .system
    @State private var presenter = ActivityPresenter()
    @State private var isPreparing = false
    @State private var copied = false
    @State private var errorMessage: String?

    /// `summary.shareUrl` is what gets shared; pass a copy with another link's URL to share that one.
    public init(summary: Summary, actionInToolbar: Bool = false, showsPrivateNote: Bool = true) {
        self.summary = summary
        self.actionInToolbar = actionInToolbar
        self.showsPrivateNote = showsPrivateNote
    }

    public var body: some View {
        Section {
            Picker(String(localized: "Share as", bundle: .module), selection: $mode) {
                ForEach(ShareMode.allCases) { mode in
                    HStack(spacing: 14) {
                        Image(systemName: mode.systemImage)
                            .font(.title3)
                            .frame(width: 28)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                            Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(isPreparing)
        } header: {
            Text("Share as", bundle: .module)
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if showsPrivateNote, summary.visibility == .private {
                Text("This summary is private, so the link won't open for anyone else. Make it public under Edit sharing.", bundle: .module)
            }
        }
        .toolbar {
            if actionInToolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await perform(mode) }
                    } label: {
                        if isPreparing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(actionTitle, systemImage: actionImage)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparing)
                    .background(ActivityPresenterAnchor(presenter: presenter))
                    .accessibilityIdentifier("share-action")
                }
            }
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .onChange(of: mode) { errorMessage = nil }

        if !actionInToolbar {
            Section {
                Button {
                    Task { await perform(mode) }
                } label: {
                    HStack(spacing: 8) {
                        if isPreparing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: actionImage)
                        }
                        Text(actionTitle)
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparing)
                .background(ActivityPresenterAnchor(presenter: presenter))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private var actionTitle: String {
        copied && mode == .copy ? String(localized: "Copied", bundle: .module) : mode.actionTitle
    }

    private var actionImage: String {
        copied && mode == .copy ? "checkmark" : (mode == .copy ? "doc.on.doc" : "square.and.arrow.up")
    }

    private func perform(_ mode: ShareMode) async {
        errorMessage = nil
        switch mode {
        case .system:
            isPreparing = true
            // The image makes the share sheet header and Mail/Photos richer, but isn't required.
            let file = try? await loader.downloadOGImage(for: summary)
            isPreparing = false
            presenter.present(RichShareItems.make(for: summary, imageFile: file))
        case .link:
            // Only the URL, so the receiving app fetches the OG preview itself.
            presenter.present([summary.shareUrl])
        case .image:
            isPreparing = true
            do {
                let file = try await loader.downloadOGImage(for: summary)
                isPreparing = false
                presenter.present([file, ShareCaption.text(for: summary)])
            } catch {
                isPreparing = false
                errorMessage = String(localized: "Couldn't download the preview image. \(error.localizedDescription)", bundle: .module)
            }
        case .copy:
            #if os(iOS)
            UIPasteboard.general.url = summary.shareUrl
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary.shareUrl.absoluteString, forType: .string)
            #endif
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Sheet asking how to share a summary. With an `api`, its owner also picks which link to share
/// and manages the links (`ShareLinksView`) without leaving the sheet.
public struct ShareModeSheet: View {
    let api: SummaryAPIClient?
    let onSummaryChanged: (Summary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var summary: Summary
    @State private var links: [SummaryShareLink] = []
    /// The extra link to share; nil shares the summary's own link.
    @State private var selectedLinkID: String?
    @State private var loadedLinks = false

    public init(summary: Summary, api: SummaryAPIClient? = nil, onSummaryChanged: @escaping (Summary) -> Void = { _ in }) {
        self._summary = State(initialValue: summary)
        self.api = api
        self.onSummaryChanged = onSummaryChanged
    }

    private var managesLinks: Bool { api != nil && summary.isOwner }
    private var liveLinks: [SummaryShareLink] { links.filter { !$0.isExpired } }
    private var selectedLink: SummaryShareLink? { liveLinks.first { $0.id == selectedLinkID } }

    /// The summary as shared: with the chosen link's URL.
    private var shared: Summary {
        var copy = summary
        if let selectedLink { copy.shareUrl = selectedLink.url }
        return copy
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    SummaryOGImage(summary: summary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } footer: {
                    Text(shared.shareUrl.absoluteString)
                        .textSelection(.enabled)
                }
                if let api, managesLinks {
                    linkSection(api: api)
                }
                #if os(macOS)
                ShareActionsSection(summary: shared, actionInToolbar: true, showsPrivateNote: !managesLinks)
                #else
                ShareActionsSection(summary: shared, showsPrivateNote: !managesLinks)
                #endif
            }
            .navigationTitle(Text("Share", bundle: .module, comment: "Title of the share sheet"))
            .summaryInlineNavigationTitle()
            .toolbar {
                #if os(macOS)
                // The share action takes the default (trailing) slot; Done closes without sharing.
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
                #else
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
                #endif
            }
            .task { await loadLinks() }
            .onChange(of: links) {
                if selectedLinkID != nil, selectedLink == nil { selectedLinkID = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .summarySheetSize()
    }

    private func linkSection(api: SummaryAPIClient) -> some View {
        Section {
            Picker(selection: $selectedLinkID) {
                Text("Summary link", bundle: .module).tag(String?.none)
                ForEach(liveLinks) { link in
                    Text(link.displayName).tag(Optional(link.id))
                }
            } label: {
                Label(String(localized: "Link", bundle: .module), systemImage: "link")
            }
            .pickerStyle(.menu)
            .sensoryFeedback(.selection, trigger: selectedLinkID)
            .accessibilityIdentifier("share-link-picker")
            NavigationLink {
                ShareLinksView(api: api, summary: $summary, links: $links) { updated in
                    onSummaryChanged(updated)
                }
            } label: {
                Label(String(localized: "Manage Links", bundle: .module), systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("manage-share-links")
        } header: {
            Text("Link to share", bundle: .module)
        } footer: {
            linkFooter
        }
    }

    @ViewBuilder
    private var linkFooter: some View {
        if let selectedLink {
            HStack(spacing: 6) {
                Text(selectedLink.access == .invited
                    ? String(localized: "Opens for \(selectedLink.emails.count) invited people.", bundle: .module)
                    : String(localized: "Opens for anyone with the link.", bundle: .module))
                ExpiryLabel(selectedLink.expiresAt)
            }
        } else if summary.visibility == .private {
            Text("The summary is private, so its own link only opens for you. Pick or add another link to share it.", bundle: .module)
        } else {
            HStack(spacing: 6) {
                Text("Opens for anyone with the link.", bundle: .module)
                ExpiryLabel(summary.expiresAt)
            }
        }
    }

    private func loadLinks() async {
        guard let api, managesLinks, !loadedLinks else { return }
        guard let fetched = try? await api.shareLinks(summaryID: summary.id) else { return }
        links = fetched
        loadedLinks = true
        // A private summary's own link doesn't open for anyone else; offer a link that does.
        if summary.visibility == .private, selectedLinkID == nil { selectedLinkID = liveLinks.first?.id }
    }
}
#endif
