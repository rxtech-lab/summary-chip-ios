import Foundation
import Kingfisher

private let logger = SummaryLog.assets

/// Loads OG images and source PDFs. For owned summaries it attaches the bearer token so private
/// summaries still render (`/s/<slug>/og.png` and `/s/<slug>/source` accept an optional
/// `Authorization: Bearer`). Images go through Kingfisher, so they share its memory + disk cache.
public final class SummaryAssetLoader: Sendable {
    let tokenProvider: (any AccessTokenProvider)?
    let session: URLSession

    /// `cacheLimitBytes` caps Kingfisher's in-memory cache (decoded pixels) for this process;
    /// extensions pass a small value to stay under their memory limit.
    public init(tokenProvider: (any AccessTokenProvider)?, session: URLSession = .shared, cacheLimitBytes: Int? = nil) {
        self.tokenProvider = tokenProvider
        self.session = session
        if let cacheLimitBytes {
            ImageCache.default.memoryStorage.config.totalCostLimit = cacheLimitBytes
        }
    }

    /// Anonymous loader (App Clip, previews).
    public static let anonymous = SummaryAssetLoader(tokenProvider: nil)

    /// Adds the bearer token to image requests when `authorized` (use for summaries the user owns).
    public func requestModifier(authorized: Bool) -> any AsyncImageDownloadRequestModifier {
        BearerTokenModifier(tokenProvider: authorized ? tokenProvider : nil)
    }

    /// Never forwards our bearer token to a redirect on another host (e.g. presigned R2 URLs).
    public var redirectHandler: any ImageDownloadRedirectHandler { StripAuthorizationRedirectHandler() }

    /// Kingfisher options for loading an image, authorised or not.
    public func imageOptions(authorized: Bool) -> KingfisherOptionsInfo {
        [.requestModifier(requestModifier(authorized: authorized)), .redirectHandler(redirectHandler), .backgroundDecode]
    }

    /// Downloads the OG PNG (or reads it from Kingfisher's cache) to a temp file named after the
    /// slug, ready to share / attach.
    public func downloadOGImage(for summary: Summary) async throws -> URL {
        guard let url = summary.ogImageUrl else { throw SummaryAPIError.invalidResponse }
        let result: RetrieveImageResult
        do {
            result = try await KingfisherManager.shared.retrieveImage(with: url, options: imageOptions(authorized: summary.isOwner))
        } catch {
            logger.error("OG image download failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        guard let data = result.data() ?? result.image.kf.pngRepresentation() else { throw SummaryAPIError.invalidResponse }
        return try Self.writeTemporary(data, name: "\(summary.slug).png")
    }

    /// Keeps downloaded images on disk long enough for saved summaries to render offline
    /// (Kingfisher's default drops them after a week).
    public static func retainImagesForOfflineUse() {
        ImageCache.default.diskStorage.config.expiration = .days(90)
        ImageCache.default.diskStorage.config.sizeLimit = 500 * 1024 * 1024
    }

    /// Drops every cached image (memory + disk); called on logout so private images don't linger.
    public static func clearImageCache() {
        ImageCache.default.clearMemoryCache()
        ImageCache.default.clearDiskCache()
    }

    /// Bytes used by cached images on disk plus downloaded share images.
    public static func imageCacheSize() async -> Int {
        let kingfisher = Int((try? await ImageCache.default.diskStorageSize) ?? 0)
        return kingfisher + FileManager.default.allocatedSize(of: temporaryDirectory)
    }

    /// Downloads the uploaded PDF (owner-authorised) to a temp file for Quick Look.
    public func downloadSourceFile(for summary: Summary) async throws -> URL {
        guard let url = summary.sourceFileUrl else { throw SummaryAPIError.invalidResponse }
        let (data, _) = try await fetch(url, authorized: summary.isOwner)
        let base = (summary.sourceTitle ?? summary.title).replacingOccurrences(of: "/", with: "-")
        return try Self.writeTemporary(data, name: "\(base.prefix(60)).pdf")
    }

    private func fetch(_ url: URL, authorized: Bool) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            if authorized, let tokenProvider,
               let token = try? await tokenProvider.accessToken(forceRefresh: attempt > 0) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request, delegate: StripAuthorizationOnRedirect())
            } catch {
                logger.error("Fetch failed for \(url.absoluteString, privacy: .public): \(error.logDescription, privacy: .public)")
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
            if !(200..<300).contains(http.statusCode) {
                logger.error("Fetch \(url.absoluteString, privacy: .public) returned HTTP \(http.statusCode)")
            }
            if http.statusCode == 401, authorized, attempt == 0 {
                attempt += 1
                continue
            }
            try SummaryAPIClient.validate(data: data, response: http)
            return (data, http)
        }
    }

    public static var temporaryDirectory: URL { SharedImageCache.temporaryDirectory }

    static func writeTemporary(_ data: Data, name: String) throws -> URL {
        let directory = temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: name)
        try data.write(to: file, options: .atomic)
        return file
    }
}

extension FileManager {
    /// Total allocated size of the files under `url` (0 if it doesn't exist).
    func allocatedSize(of url: URL) -> Int {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(0) { total, file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return total }
            return total + (values.totalFileAllocatedSize ?? 0)
        }
    }
}

/// Where downloaded share images live (purged on logout).
public enum SharedImageCache {
    public static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "SummaryChipImages", directoryHint: .isDirectory)
    }
}

/// `/s/<slug>/source` 302s to a presigned R2 URL; never forward our bearer token there.
final class StripAuthorizationOnRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var request = request
        if request.url?.host() != task.originalRequest?.url?.host() {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

struct BearerTokenModifier: AsyncImageDownloadRequestModifier {
    let tokenProvider: (any AccessTokenProvider)?
    var onDownloadTaskStarted: (@Sendable (DownloadTask?) -> Void)? { nil }

    func modified(for request: URLRequest) async -> URLRequest? {
        var request = request
        request.timeoutInterval = 60
        if let tokenProvider, let token = try? await tokenProvider.accessToken(forceRefresh: false) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

struct StripAuthorizationRedirectHandler: ImageDownloadRedirectHandler {
    func handleHTTPRedirection(for task: SessionDataTask, response: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? {
        var request = newRequest
        if request.url?.host() != task.originalURL?.host() {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// Last few summaries, stored in the App Group so the iMessage extension can show something
/// instantly before the network answers.
public enum RecentSummariesCache {
    static let key = "recentSummaries"

    static var defaults: UserDefaults? { UserDefaults(suiteName: SummaryIdentifiers.appGroupIdentifier) }

    public static func load() -> [Summary] {
        guard let data = defaults?.data(forKey: key),
              let items = try? SummaryJSON.decoder().decode([Summary].self, from: data) else { return [] }
        return items
    }

    public static func save(_ summaries: [Summary]) {
        guard let data = try? SummaryJSON.encoder().encode(Array(summaries.prefix(5))) else { return }
        defaults?.set(data, forKey: key)
    }

    public static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
