import Foundation
import WebKit

/// Reads a page in an off-screen web view on the device. The last resort after the server's plain
/// fetch and headless browser both failed (bot walls, geo blocks, app-only share links such as
/// xhslink.cn): the page loads from the user's own network in a real WebKit.
@MainActor
public final class WebPageReader: NSObject {
    public enum ReadError: Error, LocalizedError {
        case timedOut
        case loadFailed(String)
        case noContent

        public var errorDescription: String? {
            switch self {
            case .timedOut: "The page took too long to load on this device."
            case .loadFailed(let reason): "The page could not be loaded on this device. \(reason)"
            case .noContent: "Not enough readable text was found on the page."
            }
        }
    }

    /// Loads `url`, lets script-built content settle, then returns the page's readable text.
    public static func read(_ url: URL, timeout: Duration = .seconds(25)) async throws -> WebpageSource {
        try await WebPageReader().read(url, timeout: timeout)
    }

    private let webView: WKWebView
    private var loading: CheckedContinuation<Void, any Error>?

    override private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // Sites serve stripped-down pages to user agents without the Safari token.
        #if os(iOS)
        configuration.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        #else
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        #endif
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    private func read(_ url: URL, timeout: Duration) async throws -> WebpageSource {
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        let started = ContinuousClock.now
        SummaryLog.api.info("Reading \(url.absoluteString, privacy: .private) in an on-device web view")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loading = continuation
                webView.load(URLRequest(url: url, timeoutInterval: 20))
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finishLoading(.failure(ReadError.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishLoading(.failure(CancellationError())) }
        }

        // Script-built pages (and JS redirects) keep changing after `didFinish`: poll until the text stops growing.
        var best = try await extract()
        for _ in 0..<5 where ContinuousClock.now - started < timeout {
            try await Task.sleep(for: .milliseconds(750))
            let page = try await extract()
            let settled = page.text.count >= 200 && page.text.count == best.text.count
            if page.text.count >= best.text.count { best = page }
            if settled { break }
        }
        guard best.text.filter({ !$0.isWhitespace }).count >= 20 else { throw ReadError.noContent }
        SummaryLog.api.info("Read \(best.text.count) characters on the device in \(started.duration(to: .now), privacy: .public)")
        return WebpageSource(url: url, title: best.title, content: best.text, html: best.html, siteName: best.siteName, lang: best.lang)
    }

    private struct Extraction {
        var text: String
        var html: String?
        var title: String?
        var siteName: String?
        var lang: String?
    }

    private func extract() async throws -> Extraction {
        let value = try await webView.callAsyncJavaScript(Self.extractionScript, contentWorld: .defaultClient)
        let page = value as? [String: Any] ?? [:]
        // Capped to the contract's limits; some sites put a whole post in `og:title`.
        func string(_ key: String, limit: Int) -> String? {
            (page[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(limit)) }
        }
        return Extraction(
            text: string("text", limit: WebpageSource.maxContentLength) ?? "",
            html: (page["html"] as? String).flatMap { $0.isEmpty || $0.count > WebpageSource.maxHTMLLength ? nil : $0 },
            title: string("title", limit: 200),
            siteName: string("siteName", limit: 200),
            lang: string("lang", limit: 35)
        )
    }

    /// Prefers `<article>`/`<main>` over the whole body, and leads with the page description
    /// (short social posts often only carry their text there).
    private static let extractionScript = """
    const meta = (selector) => document.querySelector(selector)?.getAttribute("content")?.trim() || "";
    const textOf = (node) => (node?.innerText || "").replace(/\\n{3,}/g, "\\n\\n").trim();
    const article = document.querySelector("article");
    const main = document.querySelector("main");
    const root = textOf(article).length >= 200 ? article : textOf(main).length >= 200 ? main : document.body;
    let text = textOf(root);
    const description = meta('meta[property="og:description"]') || meta('meta[name="description"]');
    if (description && !text.includes(description.slice(0, 40))) text = `${description}\\n\\n${text}`;
    return {
      text,
      html: (\(markupScript))(root),
      title: meta('meta[property="og:title"]') || document.title || "",
      siteName: meta('meta[property="og:site_name"]'),
      lang: document.documentElement.lang || "",
    };
    """

    /// A JS function that returns an element's markup without scripts, styles or page chrome, with
    /// absolute link and image URLs (the server simplifies it further). Shared with Safari's share sheet.
    static let markupScript = """
    (root) => {
      if (!root) return "";
      const clone = root.cloneNode(true);
      // Resolve URLs while the clone still mirrors the live tree element for element.
      const live = root.querySelectorAll("a[href], img");
      clone.querySelectorAll("a[href], img").forEach((node, index) => {
        const original = live[index];
        if (node.tagName === "A") node.setAttribute("href", original.href);
        else if (original.currentSrc || original.src) node.setAttribute("src", original.currentSrc || original.src);
      });
      clone.querySelectorAll("script, style, noscript, template, svg, canvas, iframe, form, button, nav, aside, footer, [aria-hidden=true]")
        .forEach((node) => node.remove());
      return clone.innerHTML;
    }
    """

    private func finishLoading(_ result: Result<Void, any Error>) {
        guard let loading else { return }
        self.loading = nil
        loading.resume(with: result)
    }
}

extension WebPageReader: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Share links often bounce to an app scheme (xhsdiscover://…); stay on the web page.
        switch navigationAction.request.url?.scheme?.lowercased() {
        case "http", "https", "about", "data", "blob": .allow
        default: .cancel
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(.success(()))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    private func failed(_ error: any Error) {
        let nsError = error as NSError
        // A redirect or a cancelled app-scheme hop interrupts the current load; the next one continues.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        finishLoading(.failure(ReadError.loadFailed(error.localizedDescription)))
    }
}
