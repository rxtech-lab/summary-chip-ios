import CoreGraphics
import WebKit
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#endif

/// Keeps an export WebView attached to a borderless window so WebKit paints and snapshots it.
/// macOS uses an offscreen `NSWindow`; iOS uses a non-interactive window placed behind the app's own.
@MainActor
final class RenderHost {
    #if os(macOS)
    private var window: NSWindow?
    #else
    private var window: UIWindow?
    #endif

    init(webView: WKWebView, size: CGSize) throws {
        #if os(macOS)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear; window.isOpaque = false
        window.contentView = webView
        self.window = window
        #else
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .sorted(by: { $0.activationState == .foregroundActive && $1.activationState != .foregroundActive })
            .first else {
            throw RemotionError.rendering("Rendering needs the app to be open on screen")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        // Behind the app's windows: WebKit keeps painting it, but the user never sees or touches it.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 100)
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        let controller = UIViewController()
        // UIKit sizes a root controller's view to its scene, overriding a composition-sized
        // WebView. Keep the WebView as an explicitly sized child so JS sees the render viewport.
        controller.view = UIView(frame: window.bounds)
        controller.view.backgroundColor = .clear
        webView.frame = CGRect(origin: .zero, size: size)
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        #endif
    }

    func resize(_ size: CGSize) {
        #if os(macOS)
        window?.setContentSize(size)
        #else
        window?.rootViewController?.view.subviews.first?.frame = CGRect(origin: .zero, size: size)
        #endif
    }

    func close() {
        #if os(macOS)
        window?.close()
        #else
        window?.isHidden = true
        window?.rootViewController = nil
        #endif
        window = nil
    }
}

extension WKWebView {
    func setRenderSize(_ size: CGSize) {
        #if os(macOS)
        setFrameSize(size)
        #else
        frame = CGRect(origin: frame.origin, size: size)
        #endif
    }

    /// Lets a live preview layer over other content.
    func makeTransparent() {
        #if os(macOS)
        // macOS WebKit's background drawing flag is required for transparent live layers.
        setValue(false, forKey: "drawsBackground")
        #else
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        #endif
    }

    func prepareForRendering() {
        #if os(iOS)
        // A movie frame is a fixed viewport: never scroll, zoom or inset it for safe areas.
        scrollView.isScrollEnabled = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false
        #endif
    }
}

extension PlatformImage {
    var renderedCGImage: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        cgImage
        #endif
    }
}
