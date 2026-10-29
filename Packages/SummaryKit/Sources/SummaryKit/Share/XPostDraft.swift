import Foundation

/// A browser composer draft. Creating it never changes a chip's sharing permissions.
public struct XPostDraft: Sendable {
    public let text: String

    public init(title: String, summary: String, sources: [Summary]) {
        var seen = Set<URL>()
        let links = sources.compactMap { chip -> URL? in
            // Uploaded files and personal notes may have no original web source.
            let url = chip.sourceUrl ?? (chip.visibility == .public && !chip.isExpired ? chip.shareUrl : nil)
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !Self.isXLink(url), seen.insert(url).inserted else { return nil }
            return url
        }
        let overview = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = ([title, overview].filter { !$0.isEmpty } + links.map(\.absoluteString)).joined(separator: "\n\n")
    }

    /// Links back to X itself are redundant in an X post, so they are left out.
    private static func isXLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["x.com", "twitter.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "x.com"
        components.path = "/intent/tweet"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url!
    }
}
