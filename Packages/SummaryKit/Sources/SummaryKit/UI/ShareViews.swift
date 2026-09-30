#if os(iOS)
import LinkPresentation
import SwiftUI
import UIKit

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
        case .system: "Everything"
        case .link: "Link"
        case .image: "Image"
        case .copy: "Copy link"
        }
    }

    public var detail: String {
        switch self {
        case .system: "Link preview, image and the full summary. Each app takes what it supports."
        case .link: "Messages, Slack and others render the preview card from the link."
        case .image: "Sends the preview image with the title and link as a caption."
        case .copy: "Copies the link to the clipboard."
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
        case .copy: "Copy link"
        default: "Share"
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

/// Share mode picker plus a single share button. Reused by the share sheet, the new-summary
/// result screen and the share extension's result screen.
public struct ShareActionsSection: View {
    let summary: Summary

    @Environment(\.summaryAssetLoader) private var loader
    @AppStorage("shareMode") private var mode: ShareMode = .system
    @State private var presenter = ActivityPresenter()
    @State private var isPreparing = false
    @State private var copied = false
    @State private var errorMessage: String?

    public init(summary: Summary) { self.summary = summary }

    public var body: some View {
        Section {
            Picker("Share as", selection: $mode) {
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
            Text("Share as")
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if summary.visibility == .private {
                Text("This summary is private, so the link won't open for anyone else. Make it public under Edit sharing.")
            }
        }

        Section {
            Button {
                Task { await perform(mode) }
            } label: {
                HStack(spacing: 8) {
                    if isPreparing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: copied && mode == .copy ? "checkmark" : (mode == .copy ? "doc.on.doc" : "square.and.arrow.up"))
                    }
                    Text(copied && mode == .copy ? "Copied" : mode.actionTitle)
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
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .onChange(of: mode) { errorMessage = nil }
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
                errorMessage = "Couldn't download the preview image. \(error.localizedDescription)"
            }
        case .copy:
            UIPasteboard.general.url = summary.shareUrl
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Sheet asking how to share a summary.
public struct ShareModeSheet: View {
    let summary: Summary
    @Environment(\.dismiss) private var dismiss

    public init(summary: Summary) { self.summary = summary }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    SummaryOGImage(summary: summary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } footer: {
                    Text(summary.shareUrl.absoluteString)
                        .textSelection(.enabled)
                }
                ShareActionsSection(summary: summary)
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
