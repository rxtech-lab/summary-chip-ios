import Messages
import SummaryKit
import SwiftUI
import UIKit

/// iMessage app: compact mode shows "Paste link" and recent summaries; expanded mode runs the
/// full creation flow and sends the result as a rich link or as an image.
final class MessagesViewController: MSMessagesAppViewController {
    private let state = MessagesState()
    private var host: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        state.requestStyle = { [weak self] style in self?.requestPresentationStyle(style) }
        state.insertLink = { [weak self] url in self?.insertLink(url) }
        state.insertImage = { [weak self] file, url in self?.insertImage(file, link: url) }
        state.openApp = { [weak self] url in self?.extensionContext?.open(url) }

        let root = MessagesRootView(state: state)
            .environment(\.summaryAssetLoader, state.assetLoader)
        let host = UIHostingController(rootView: AnyView(root))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        state.presentationStyle = presentationStyle
        Task { await state.refresh() }
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        state.presentationStyle = presentationStyle
    }

    private func insertLink(_ url: URL) {
        guard let conversation = activeConversation else { return }
        Task {
            // Plain URL text: Messages fetches the OG tags and renders the rich link preview.
            try? await conversation.insertText(url.absoluteString)
            dismissAfterInsert()
        }
    }

    private func insertImage(_ file: URL, link: URL) {
        guard let conversation = activeConversation else { return }
        Task {
            try? await conversation.insertAttachment(file, withAlternateFilename: file.lastPathComponent)
            try? await conversation.insertText(link.absoluteString)
            dismissAfterInsert()
        }
    }

    private func dismissAfterInsert() {
        if presentationStyle != .compact { requestPresentationStyle(.compact) }
        state.resetFlow()
    }
}
