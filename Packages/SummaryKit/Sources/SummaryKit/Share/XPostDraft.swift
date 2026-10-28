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
                  seen.insert(url).inserted else { return nil }
            return url
        }
        let overview = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = ([title, overview].filter { !$0.isEmpty } + links.map(\.absoluteString)).joined(separator: "\n\n")
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
