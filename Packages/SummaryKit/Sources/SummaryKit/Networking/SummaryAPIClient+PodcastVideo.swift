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
}

private struct PodcastVideoEnvelope: Decodable { var video: PodcastVideoSource }
private struct PodcastEpisodeEnvelope: Decodable { var podcast: DailyPodcast }
private struct PodcastVideoDay: Encodable { var start: String; var end: String }
// `language` is only sent for a translation, so the original's requests are unchanged.
private struct PodcastVideoCompose: Encodable { var day: PodcastVideoDay; var language: String? }
private struct PodcastVideoUpload: Encodable { var day: PodcastVideoDay; var videoId: String; var byteSize: Int; var language: String? }
private struct PodcastVideoPublication: Encodable { var day: PodcastVideoDay; var videoId: String; var language: String? }
private struct PodcastVideoTicket: Decodable {
    var uploadUrl: URL
    var method: String
    var headers: [String: String]
}

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

    /// Starts designing a new composition on the server (spends points when it finishes). Returns at once
    /// with the episode's `videoDesign`; the design continues while the app is in the background.
    public func composePodcastVideo(_ podcast: DailyPodcast) async throws -> DailyPodcast {
        let envelope: PodcastEpisodeEnvelope = try await send(json(videoPath(podcast), method: "POST",
            body: PodcastVideoCompose(day: videoDay(podcast), language: podcast.translationLanguage)))
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
