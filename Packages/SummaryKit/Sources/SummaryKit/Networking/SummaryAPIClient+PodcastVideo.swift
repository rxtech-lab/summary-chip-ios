import Foundation

/// An episode's Remotion project, written by the server's video model and rendered on device.
public struct PodcastVideoSource: Decodable, Sendable, Equatable {
    public struct Chip: Decodable, Sendable, Equatable {
        public var id: String
        public var title: String
    }
    public var id: String
    public var model: String
    public var fps: Double
    public var width: Int
    public var height: Int
    public var chips: [Chip]
    /// Project files keyed by relative path; `src/index.ts` is the entry point.
    public var files: [String: String]
    /// Transparent cut-outs the video agent generated, placed under `public/` for `staticFile()`.
    public var assets: [Asset]?

    public struct Asset: Decodable, Sendable, Equatable {
        /// Path under `public/`, e.g. `gen/rocket.png`.
        public var path: String
        /// Short-lived signed download URL.
        public var url: URL
        public var width: Int
        public var height: Int
    }
}

private struct PodcastVideoEnvelope: Decodable { var video: PodcastVideoSource }
private struct PodcastEpisodeEnvelope: Decodable { var podcast: DailyPodcast }
private struct PodcastVideoDay: Encodable { var start: String; var end: String }
// `language` is only sent for a translation, so the original's requests are unchanged.
private struct PodcastVideoCompose: Encodable { var day: PodcastVideoDay; var language: String?; var videoStyle: PodcastVideoStyle? }
private struct PodcastVideoUpload: Encodable { var day: PodcastVideoDay; var videoId: String; var byteSize: Int; var language: String? }
private struct PodcastVideoPublication: Encodable { var day: PodcastVideoDay; var videoId: String; var language: String? }
private struct PodcastVideoTicket: Decodable {
    var uploadUrl: URL
    var method: String
    var headers: [String: String]
}
private struct PodcastCloudRenderInput: Encodable { var day: PodcastVideoDay; var language: String?; var resolution: Int }
/// A private cloud render of one composition. It waits in a queue (`isQueued`) until the renderer starts it.
public struct PodcastRenderState: Codable, Sendable, Equatable {
    public var id: String
    public var status: String
    public var resolution: Int
    public var startedAt: Date?
    public var byteSize: Int?
    public var error: APIErrorBody?
    public var isRunning: Bool { status == "running" }
    public var isQueued: Bool { isRunning && startedAt == nil }
    public var isReady: Bool { status == "ready" }
}
private struct PodcastCloudRender: Decodable {
    var videoId: String?
    var render: PodcastRenderState?
    var downloadUrl: URL?
}
private struct PodcastVideoDownload: Decodable { var videoId: String; var downloadUrl: URL }

extension SummaryAPIClient {
    static func isPodcastVideoPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix("/api/v1/daily-podcasts/") && path.hasSuffix("/video")
    }

    /// The day the episode was recorded for, independent of the viewer's current time zone.
    func podcastDayBounds(_ podcast: DailyPodcast) throws -> PodcastDayBounds {
        let day = try videoDay(podcast)
        return PodcastDayBounds(start: day.start, end: day.end)
    }

    private func videoQuery(_ podcast: DailyPodcast) throws -> [URLQueryItem] {
        let day = try videoDay(podcast)
        var query = [URLQueryItem(name: "start", value: day.start), URLQueryItem(name: "end", value: day.end)]
        if let language = podcast.translationLanguage { query.append(URLQueryItem(name: "language", value: language)) }
        return query
    }

    private func videoDay(_ podcast: DailyPodcast) throws -> PodcastVideoDay {
        if let day = podcast.day { return PodcastVideoDay(start: day.start, end: day.end) }
        guard let path = podcast.audioPath, let items = URLComponents(string: path)?.queryItems,
              let start = items.first(where: { $0.name == "start" })?.value,
              let end = items.first(where: { $0.name == "end" })?.value else { throw SummaryAPIError.invalidResponse }
        return PodcastVideoDay(start: start, end: end)
    }

    private func videoPath(_ podcast: DailyPodcast, _ suffix: String = "") -> String {
        "/api/v1/daily-podcasts/\(podcast.key.urlPathEscaped)/video\(suffix)"
    }

    /// The composition to render. Never calls a model or spends points.
    public func podcastVideoSource(_ podcast: DailyPodcast) async throws -> PodcastVideoSource {
        let envelope: PodcastVideoEnvelope = try await send(request(videoPath(podcast), query: try videoQuery(podcast)))
        return envelope.video
    }

    /// Downloads one generated cut-out of a composition from its signed URL (no account token).
    public func podcastVideoAsset(_ asset: PodcastVideoSource.Asset) async throws -> Data {
        var download = URLRequest(url: asset.url)
        download.timeoutInterval = 120
        let (data, response) = try await session.data(for: download)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        guard http.statusCode == 200 else { throw SummaryAPIError.http(status: http.statusCode) }
        guard !data.isEmpty else { throw SummaryAPIError.invalidResponse }
        return data
    }

    /// Downloads the published MP4 to a temporary file. The caller moves it into its video cache.
    /// Only the ticket request uses the account token; storage uses its short-lived signed URL.
    public func downloadPublishedPodcastVideo(_ podcast: DailyPodcast, onProgress: MediaTransferProgress.Handler? = nil) async throws -> URL {
        guard let video = podcast.video, video.isPublished else { throw SummaryAPIError.invalidResponse }
        let ticket: PodcastVideoDownload = try await send(request(videoPath(podcast, "/publication"), query: try videoQuery(podcast)))
        guard ticket.videoId == video.id else { throw SummaryAPIError.invalidResponse }
        var download = URLRequest(url: ticket.downloadUrl)
        download.timeoutInterval = 600
        await onProgress?(.init(completedBytes: 0, totalBytes: video.published.map { Int64($0.byteSize) }))
        let delegate = onProgress.map { MediaTransferDelegate($0) }
        let (file, response) = try await session.download(for: download, delegate: delegate)
        do {
            guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
            guard http.statusCode == 200 else { throw SummaryAPIError.http(status: http.statusCode) }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size == video.published?.byteSize else { throw SummaryAPIError.invalidResponse }
            try Task.checkCancellation()
            await onProgress?(.init(completedBytes: Int64(size), totalBytes: Int64(size)))
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Starts/reuses a durable cloud render and downloads the private R2 output. Closing the
    /// sheet cancels polling and downloading; the server continues rendering for later reuse.
    public func downloadCloudPodcastVideo(_ podcast: DailyPodcast, resolution: Int = 1080,
                                          onProgress: MediaTransferProgress.Handler? = nil,
                                          onRender: (@MainActor @Sendable (PodcastRenderState) -> Void)? = nil) async throws -> URL {
        let state = try await cloudPodcastRender(podcast, resolution: resolution, onRender: onRender)
        guard let url = state.downloadUrl, let size = state.render?.byteSize, size > 0 else { throw SummaryAPIError.invalidResponse }
        var download = URLRequest(url: url)
        download.timeoutInterval = 600
        await onProgress?(.init(completedBytes: 0, totalBytes: Int64(size)))
        let delegate = onProgress.map { MediaTransferDelegate($0) }
        let (file, response) = try await session.download(for: download, delegate: delegate)
        do {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else { throw SummaryAPIError.invalidResponse }
            try Task.checkCancellation()
            await onProgress?(.init(completedBytes: Int64(size), totalBytes: Int64(size)))
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Queues a cloud render and returns immediately so the user can follow it in Background Jobs.
    public func startCloudPodcastRender(_ podcast: DailyPodcast, resolution: Int = 1080) async throws -> PodcastRenderState {
        guard [720, 1080].contains(resolution), let video = podcast.video else { throw SummaryAPIError.invalidResponse }
        let state: PodcastCloudRender = try await send(json(videoPath(podcast, "/render"), method: "POST",
            body: PodcastCloudRenderInput(day: videoDay(podcast), language: podcast.translationLanguage, resolution: resolution)))
        if let error = state.render?.error { throw SummaryAPIError.server(status: 502, body: error) }
        guard state.videoId == video.id, let render = state.render, render.isRunning || render.isReady else {
            throw SummaryAPIError.invalidResponse
        }
        return render
    }

    /// Waits until the cloud render of the current composition is ready, reporting queued/rendering states.
    /// Starts it if none is running (the server reuses an existing render); never downloads.
    public func waitForCloudPodcastRender(_ podcast: DailyPodcast, resolution: Int = 1080,
                                          onRender: (@MainActor @Sendable (PodcastRenderState) -> Void)? = nil) async throws -> PodcastRenderState {
        guard let render = try await cloudPodcastRender(podcast, resolution: resolution, onRender: onRender).render else {
            throw SummaryAPIError.invalidResponse
        }
        return render
    }

    private func cloudPodcastRender(_ podcast: DailyPodcast, resolution: Int,
                                    onRender: (@MainActor @Sendable (PodcastRenderState) -> Void)?) async throws -> PodcastCloudRender {
        guard [720, 1080].contains(resolution), let video = podcast.video else { throw SummaryAPIError.invalidResponse }
        let path = videoPath(podcast, "/render")
        var state: PodcastCloudRender = try await send(json(path, method: "POST",
            body: PodcastCloudRenderInput(day: videoDay(podcast), language: podcast.translationLanguage, resolution: resolution)))
        let renderID = state.render?.id
        let query = try videoQuery(podcast) + [URLQueryItem(name: "resolution", value: String(resolution))]
        while let render = state.render, render.isRunning {
            try Task.checkCancellation()
            guard state.videoId == video.id, render.id == renderID else { throw SummaryAPIError.invalidResponse }
            await onRender?(render)
            try await Task.sleep(for: .seconds(3))
            state = try await send(request(path, query: query))
        }
        if let error = state.render?.error { throw SummaryAPIError.server(status: 502, body: error) }
        guard state.videoId == video.id, let render = state.render, render.id == renderID, render.resolution == resolution,
              render.isReady else { throw SummaryAPIError.invalidResponse }
        await onRender?(render)
        return state
    }

    /// Starts designing a new composition on the server (spends points when it finishes). Returns at once
    /// with the episode's `videoDesign`; the design continues while the app is in the background.
    /// `style` picks the art direction; `nil` leaves the server's default (news).
    public func composePodcastVideo(_ podcast: DailyPodcast, style: PodcastVideoStyle? = nil) async throws -> DailyPodcast {
        let envelope: PodcastEpisodeEnvelope = try await send(json(videoPath(podcast), method: "POST",
            body: PodcastVideoCompose(day: videoDay(podcast), language: podcast.translationLanguage, videoStyle: style)))
        return envelope.podcast
    }

    /// Follows a background video design by polling the episode (free) until it ends. Returns the episode
    /// with its new `video`, or throws the server's error when the design failed.
    public func waitForPodcastVideoDesign(_ podcast: DailyPodcast, interval: Duration = .seconds(3),
                                          onProgress: (@MainActor @Sendable (PodcastGenerationProgress) -> Void)? = nil) async throws -> DailyPodcast {
        var current = podcast
        while current.isDesigningVideo, let design = current.videoDesign {
            await onProgress?(design.progress)
            try await Task.sleep(for: interval)
            current = try await podcastEpisode(current, language: current.language)
        }
        if let failure = current.videoDesign?.error { throw SummaryAPIError.server(status: 502, body: failure) }
        return current
    }

    /// Uploads an MP4 render of `videoId` straight to storage and makes share links play it.
    public func publishPodcastVideo(_ podcast: DailyPodcast, videoId: String, fileURL: URL, onProgress: MediaTransferProgress.Handler? = nil) async throws -> DailyPodcast {
        let day = try videoDay(podcast)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ticket: PodcastVideoTicket = try await send(json(videoPath(podcast, "/upload"), method: "POST",
            body: PodcastVideoUpload(day: day, videoId: videoId, byteSize: size, language: podcast.translationLanguage)))
        var put = URLRequest(url: ticket.uploadUrl)
        put.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        put.timeoutInterval = 600
        for (name, value) in ticket.headers { put.setValue(value, forHTTPHeaderField: name) }
        // Streams from disk; the presigned URL carries its own authorization.
        await onProgress?(.init(completedBytes: 0, totalBytes: Int64(size)))
        let delegate = onProgress.map { MediaTransferDelegate($0) }
        let (_, response) = try await session.upload(for: put, fromFile: fileURL, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SummaryAPIError.uploadFailed(status: http.statusCode) }
        let envelope: PodcastEpisodeEnvelope = try await send(json(videoPath(podcast, "/publication"), method: "POST",
            body: PodcastVideoPublication(day: day, videoId: videoId, language: podcast.translationLanguage)))
        return envelope.podcast
    }

    /// Stops share links playing the video; they fall back to audio.
    public func unpublishPodcastVideo(_ podcast: DailyPodcast) async throws -> DailyPodcast {
        var remove = request(videoPath(podcast, "/publication"), query: try videoQuery(podcast))
        remove.httpMethod = "DELETE"
        let envelope: PodcastEpisodeEnvelope = try SummaryJSON.decoder().decode(PodcastEpisodeEnvelope.self, from: try await sendRaw(remove))
        return envelope.podcast
    }
}
