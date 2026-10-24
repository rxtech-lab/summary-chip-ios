import RxRemotion
import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformView = NSView
typealias PlatformRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformView = UIView
typealias PlatformRepresentable = UIViewRepresentable
#endif

/// Each mounted session owns its playhead. The caller controls session disposal.
public struct RemotionPreview: PlatformRepresentable {
    public let session: RemotionPreviewSession
    public init(session: RemotionPreviewSession) { self.session = session }
    #if os(macOS)
    public func makeNSView(context: Context) -> NSView { makeContainer() }
    public func updateNSView(_ view: NSView, context: Context) { mount(in: view) }
    #else
    public func makeUIView(context: Context) -> UIView { makeContainer() }
    public func updateUIView(_ view: UIView, context: Context) { mount(in: view) }
    #endif
    private func makeContainer() -> PlatformView {
        let container = PlatformView()
        mount(in: container)
        return container
    }
    private func mount(in container: PlatformView) {
        let webView = session.webView
        guard container.subviews.first !== webView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        #if os(macOS)
        webView.autoresizingMask = [.width, .height]
        #else
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        container.addSubview(webView)
    }
}
