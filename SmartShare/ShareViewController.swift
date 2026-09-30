import SummaryKit
import SwiftUI
import UIKit

/// Principal class of the share extension. Hosts the SwiftUI flow.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        isModalInPresentation = true
        let context = extensionContext
        let root = ShareRootView(
            inputItems: context?.inputItems ?? [],
            finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            cancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            },
            openURL: { [weak self] url in self?.openContainingApp(url) }
        )
        let host = UIHostingController(rootView: root)
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
    }

    /// Share extensions can't call `UIApplication.open`; walk the responder chain to the host
    /// application and invoke `open(_:options:completionHandler:)` dynamically.
    private func openContainingApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenMethod = @convention(c) (NSObject, Selector, NSURL, NSDictionary, Any?) -> Void
                let implementation = application.method(for: selector)
                let open = unsafeBitCast(implementation, to: OpenMethod.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                break
            }
            responder = current.next
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
