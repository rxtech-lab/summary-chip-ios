import Foundation

public struct DailyPodcast: Codable, Sendable, Equatable {
    public struct Speaker: Codable, Sendable, Equatable {
        public var name: String
        public var voice: String
    }
    public struct Segment: Codable, Sendable, Equatable {
        public var speaker: Int
        public var chipId: String
        public var caption: String
        public var audioPath: String?
        public var startSeconds: Double?
        public var endSeconds: Double?
        /// When the voice is audible within the turn and where it pauses, in episode seconds.
        public var voiceStartSeconds: Double?
        public var voiceEndSeconds: Double?
        public var pauseSeconds: [Double]?
        public var imagePath: String?
        public var icon: String
    }
    public var key: String
    public var title: String
    public var language: String
    public var createdAt: Date
    public var speakers: [Speaker]
    public var segments: [Segment]
    public var audioPath: String?
    public var durationSeconds: Double?

    public func segmentIndex(at time: Double) -> Int {
        segments.lastIndex { ($0.startSeconds ?? 0) <= time } ?? 0
    }
}

private struct PodcastEnvelope: Decodable { var podcast: DailyPodcast? }
private struct PodcastDay: Encodable { var start: String; var end: String }
private struct PodcastRequest: Encodable {
    var day: PodcastDay
    var language: String
    var regenerate: Bool
}

/// Body of a podcast share link's `POST` (with the episode's `day`) and `PATCH`: only the name and
/// lifetime, since podcast links always open for anyone holding them. `ttl = .never` sends `null`.
private struct PodcastShareLinkRequest: Encodable {
    var day: PodcastDay?
    var changes: ShareLinkChanges

    enum CodingKeys: String, CodingKey { case day, label, ttlDays }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(day, forKey: .day)
        try container.encodeIfPresent(changes.label, forKey: .label)
        if let ttl = changes.ttl {
            if let days = ttl.ttlDays { try container.encode(days, forKey: .ttlDays) }
            else { try container.encodeNil(forKey: .ttlDays) }
        }
    }
}

extension SummaryAPIClient {
    // MARK: Podcast share links (owner only)

    public func podcastShareLinks(key: String) async throws -> [SummaryShareLink] {
        let list: ShareLinkList = try await send(request("/api/v1/daily-podcasts/\(key.urlPathEscaped)/links"))
        return list.items
    }

    public func createPodcastShareLink(_ podcast: DailyPodcast, changes: ShareLinkChanges) async throws -> SummaryShareLink {
        // Use the episode's original day boundaries, independent of the viewer's current time zone.
        guard let path = podcast.audioPath, let components = URLComponents(string: path),
              let start = components.queryItems?.first(where: { $0.name == "start" })?.value,
              let end = components.queryItems?.first(where: { $0.name == "end" })?.value else {
            throw SummaryAPIError.invalidResponse
        }
        return try await send(json("/api/v1/daily-podcasts/\(podcast.key.urlPathEscaped)/links", method: "POST", body: PodcastShareLinkRequest(
            day: PodcastDay(start: start, end: end), changes: changes
        )))
    }

    public func updatePodcastShareLink(key: String, linkID: String, changes: ShareLinkChanges) async throws -> SummaryShareLink {
        try await send(json("/api/v1/daily-podcasts/\(key.urlPathEscaped)/links/\(linkID.urlPathEscaped)", method: "PATCH",
                            body: PodcastShareLinkRequest(day: nil, changes: changes)))
    }

    public func deletePodcastShareLink(key: String, linkID: String) async throws {
        var request = request("/api/v1/daily-podcasts/\(key.urlPathEscaped)/links/\(linkID.urlPathEscaped)")
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }

    private func podcastDay(_ date: Date, calendar: Calendar) -> PodcastDay {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let formatter = ISO8601DateFormatter()
        return PodcastDay(start: formatter.string(from: start), end: formatter.string(from: end))
    }

    public func dailyPodcast(date: Date, calendar: Calendar = .current) async throws -> DailyPodcast? {
        let day = podcastDay(date, calendar: calendar)
        let envelope: PodcastEnvelope = try await send(request("/api/v1/daily-podcasts", query: [
            URLQueryItem(name: "start", value: day.start), URLQueryItem(name: "end", value: day.end)
        ]))
        return envelope.podcast
    }

    public func generateDailyPodcast(date: Date, language: SummaryLanguage, regenerate: Bool, calendar: Calendar = .current) async throws -> DailyPodcast {
        var request = try json("/api/v1/daily-podcasts", method: "POST", body: PodcastRequest(
            day: podcastDay(date, calendar: calendar), language: language.rawValue, regenerate: regenerate
        ))
        request.timeoutInterval = 300
        let envelope: PodcastEnvelope = try await send(request)
        guard let podcast = envelope.podcast else { throw SummaryAPIError.invalidResponse }
        return podcast
    }

    public func dailyPodcastAudio(_ segment: DailyPodcast.Segment) async throws -> Data {
        // Parse query items separately: URL.appending(path:) percent-escapes '?' in a path.
        guard let path = segment.audioPath, let components = URLComponents(string: path), components.path.hasPrefix("/api/v1/daily-podcasts/") else {
            throw SummaryAPIError.invalidResponse
        }
        return try await sendRaw(request(components.path, query: components.queryItems ?? []))
    }

    /// Downloads the complete persisted episode, never generating audio during playback or export.
    public func dailyPodcastAudio(_ podcast: DailyPodcast) async throws -> Data {
        guard let path = podcast.audioPath, let components = URLComponents(string: path),
              components.path.hasPrefix("/api/v1/daily-podcasts/"), components.path.hasSuffix("/audio") else {
            throw SummaryAPIError.invalidResponse
        }
        var download = request(components.path, query: components.queryItems ?? [])
        download.timeoutInterval = 120
        return try await sendRaw(download)
    }

    public func dailyPodcastArtwork(_ path: String) async throws -> Data {
        guard path.hasPrefix("/s/"), !path.contains("?") else { throw SummaryAPIError.invalidResponse }
        return try await sendRaw(request(path))
    }

    public func dailyPodcastImageURL(_ path: String?) -> URL? {
        guard let path else { return nil }
        return request(path).url
    }
}
