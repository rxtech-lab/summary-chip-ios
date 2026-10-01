import AppKit
import SummaryKit
import SwiftUI

final class ShareViewController: NSViewController {
    override func loadView() {
        let root = ShareRootView(
            inputItems: extensionContext?.inputItems ?? [],
            finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            cancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            },
            openURL: { url in
                NSWorkspace.shared.open(url)
            }
        )
        let host = NSHostingController(rootView: root)
        addChild(host)
        view = host.view
        preferredContentSize = NSSize(width: 600, height: 640)
    }
}
