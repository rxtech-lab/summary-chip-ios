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
private struct PodcastVideoCompose: Encodable { var day: PodcastVideoDay }
private struct PodcastVideoUpload: Encodable { var day: PodcastVideoDay; var videoId: String; var byteSize: Int }
private struct PodcastVideoPublication: Encodable { var day: PodcastVideoDay; var videoId: String }
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
        let day = try videoDay(podcast)
        let envelope: PodcastVideoEnvelope = try await send(request(videoPath(podcast), query: [
            URLQueryItem(name: "start", value: day.start), URLQueryItem(name: "end", value: day.end),
        ]))
        return envelope.video
    }

    /// Has the video model write a new composition (spends points). Returns the updated episode.
    public func composePodcastVideo(_ podcast: DailyPodcast,
                                    onProgress: (@MainActor @Sendable (PodcastGenerationProgress) -> Void)? = nil) async throws -> DailyPodcast {
        var request = try json(videoPath(podcast), method: "POST", body: PodcastVideoCompose(day: videoDay(podcast)))
        request.timeoutInterval = 300
        if let onProgress {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            return try await receivePodcast(request, onProgress: onProgress)
        }
        let envelope: PodcastEpisodeEnvelope = try await send(request)
        return envelope.podcast
    }

    /// Uploads an MP4 render of `videoId` straight to storage and makes share links play it.
    public func publishPodcastVideo(_ podcast: DailyPodcast, videoId: String, fileURL: URL) async throws -> DailyPodcast {
        let day = try videoDay(podcast)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ticket: PodcastVideoTicket = try await send(json(videoPath(podcast, "/upload"), method: "POST",
            body: PodcastVideoUpload(day: day, videoId: videoId, byteSize: size)))
        var put = URLRequest(url: ticket.uploadUrl)
        put.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        put.timeoutInterval = 600
        for (name, value) in ticket.headers { put.setValue(value, forHTTPHeaderField: name) }
        // Streams from disk; the presigned URL carries its own authorization.
        let (_, response) = try await session.upload(for: put, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SummaryAPIError.uploadFailed(status: http.statusCode) }
        let envelope: PodcastEpisodeEnvelope = try await send(json(videoPath(podcast, "/publication"), method: "POST",
            body: PodcastVideoPublication(day: day, videoId: videoId)))
        return envelope.podcast
    }

    /// Stops share links playing the video; they fall back to audio.
    public func unpublishPodcastVideo(_ podcast: DailyPodcast) async throws -> DailyPodcast {
        let day = try videoDay(podcast)
        var remove = request(videoPath(podcast, "/publication"), query: [
            URLQueryItem(name: "start", value: day.start), URLQueryItem(name: "end", value: day.end),
        ])
        remove.httpMethod = "DELETE"
        let envelope: PodcastEpisodeEnvelope = try SummaryJSON.decoder().decode(PodcastEpisodeEnvelope.self, from: try await sendRaw(remove))
        return envelope.podcast
    }
}
