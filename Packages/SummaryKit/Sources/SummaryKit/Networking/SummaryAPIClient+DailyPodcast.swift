import Foundation

public struct PodcastGenerationProgress: Decodable, Sendable, Equatable {
    public let stage: String
    public let percent: Int
    public let completedSteps: Int?
    public let completedSegments: Int?
    public let totalSegments: Int?

    public var fraction: Double { Double(min(100, max(0, percent))) / 100 }
    public var title: String {
        switch stage {
        case "script": String(localized: "Writing script…", bundle: .module)
        case "translating": String(localized: "Translating script…", bundle: .module)
        case "speech": String(localized: "Generating voices…", bundle: .module)
        case "music": String(localized: "Preparing music…", bundle: .module)
        case "mixing": String(localized: "Mixing audio and aligning captions…", bundle: .module)
        case "video-design": String(localized: "Designing video…", bundle: .module)
        case "video": String(localized: "Preparing video…", bundle: .module)
        case "saving": String(localized: "Saving podcast…", bundle: .module)
        case "complete": String(localized: "Podcast ready", bundle: .module)
        default: String(localized: "Preparing podcast…", bundle: .module)
        }
    }
}

struct PodcastGenerationEvent: Decodable {
    let type: String
    let progress: PodcastGenerationProgress?
    let podcast: DailyPodcast?
    let status: Int?
    let error: APIErrorBody?
}

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
        public var captionCues: [PodcastCaptionTimeline.Cue]?
        public var imagePath: String?
        public var icon: String
    }
    public var summaryId: String?
    public var day: PodcastDayBounds?
    public var key: String
    public var title: String
    /// The language this episode is presented in; a translation shares the original's key and day.
    public var language: String
    /// The language it was generated in, and every language it can play in (original first).
    public var originalLanguage: String?
    public var languages: [String]?
    public var createdAt: Date
    public var speakers: [Speaker]
    public var segments: [Segment]
    public var audioPath: String?
    public var durationSeconds: Double?
    /// bright, calm, focused, warm or reflective.
    public var mood: String?
    /// The agent-written motion video, rendered on device; nil when the episode has none.
    public var video: Video?

    public struct Video: Codable, Sendable, Equatable {
        public struct Publication: Codable, Sendable, Equatable {
            public var videoId: String
            public var byteSize: Int
            public var publishedAt: String
        }
        /// Changes when the composition is rewritten; renders are cached and published per id.
        public var id: String
        public var createdAt: String
        public var published: Publication?
        /// Whether share links play the render of the current composition.
        public var isPublished: Bool { published?.videoId == id }
    }

    public var sourceLanguage: String { originalLanguage ?? language }
    public var availableLanguages: [String] { languages ?? [language] }
    public var isTranslation: Bool { language != sourceLanguage }
    /// The `language` query/body value for this presentation: nil for the original recording.
    var translationLanguage: String? { isTranslation ? language : nil }

    public func segmentIndex(at time: Double) -> Int {
        segments.lastIndex { ($0.startSeconds ?? 0) <= time } ?? 0
    }
}

public struct PodcastDayBounds: Codable, Sendable, Equatable {
    public var start: String
    public var end: String
}
public struct PodcastChip: Decodable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var source: SummaryOrigin
    public init(id: String, title: String, source: SummaryOrigin) {
        self.id = id; self.title = title; self.source = source
    }
}
public struct PodcastVersion: Decodable, Identifiable, Sendable {
    public var podcast: DailyPodcast
    public var isDefault: Bool
    public var id: String { podcast.key }
}
private struct PodcastVersions: Decodable { var items: [PodcastVersion] }
private struct PodcastChips: Decodable { var items: [PodcastChip] }
private struct PodcastEnvelope: Decodable { var podcast: DailyPodcast? }
private struct PodcastDay: Encodable { var start: String; var end: String }
private struct PodcastRequest: Encodable {
    var day: PodcastDay
    var language: String
    var regenerate: Bool
    var chipIds: [String]?
    var library: Bool
    var includeVideo: Bool
    var summaryId: String?
}
private struct PodcastTranslationRequest: Encodable {
    var day: PodcastDay
    var language: String
    var includeVideo: Bool
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

    /// `summaryID` regenerates that library podcast chip as a new version instead of creating another chip.
    public func generateDailyPodcast(date: Date, language: SummaryLanguage, regenerate: Bool, chipIds: [String]? = nil, library: Bool = false, includeVideo: Bool = true,
                                     summaryID: String? = nil, calendar: Calendar = .current,
                                     onProgress: (@MainActor @Sendable (PodcastGenerationProgress) -> Void)? = nil) async throws -> DailyPodcast {
        var request = try json("/api/v1/daily-podcasts", method: "POST", body: PodcastRequest(
            day: podcastDay(date, calendar: calendar), language: language.rawValue, regenerate: regenerate, chipIds: chipIds, library: library, includeVideo: includeVideo,
            summaryId: summaryID
        ))
        request.timeoutInterval = 300
        if let onProgress {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            return try await receivePodcast(request, onProgress: onProgress)
        }
        let envelope: PodcastEnvelope = try await send(request)
        guard let podcast = envelope.podcast else { throw SummaryAPIError.invalidResponse }
        return podcast
    }

    func receivePodcast(_ request: URLRequest,
                                onProgress: @MainActor @Sendable (PodcastGenerationProgress) -> Void) async throws -> DailyPodcast {
        for attempt in 0...1 {
            var authorized = request
            do {
                let token = try await tokenProvider.accessToken(forceRefresh: attempt > 0)
                authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } catch TokenBrokerError.missingSession { throw SummaryAPIError.notSignedIn }
            await applyBillingProof(to: &authorized)
            let (bytes, response) = try await session.bytes(for: authorized)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
            if http.statusCode == 401 && attempt == 0 { continue }
            let streaming = http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true
            if !(200..<300).contains(http.statusCode) || !streaming {
                // Older servers can still return the completed JSON from this same POST.
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                try Self.validate(data: data, response: http)
                guard let podcast = try SummaryJSON.decoder().decode(PodcastEnvelope.self, from: data).podcast else {
                    throw SummaryAPIError.invalidResponse
                }
                return podcast
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let event = try SummaryJSON.decoder().decode(PodcastGenerationEvent.self, from: Data(line.dropFirst(5).utf8))
                switch event.type {
                case "progress":
                    guard let progress = event.progress else { throw SummaryAPIError.invalidResponse }
                    await onProgress(progress)
                case "complete":
                    guard let podcast = event.podcast else { throw SummaryAPIError.invalidResponse }
                    return podcast
                case "error":
                    guard let error = event.error else { throw SummaryAPIError.invalidResponse }
                    throw SummaryAPIError.server(status: event.status ?? 500, body: error)
                default: continue
                }
            }
            // An interrupted stream is never success and must not automatically replay a paid POST.
            throw SummaryAPIError.invalidResponse
        }
        throw SummaryAPIError.notSignedIn
    }

    public func podcastVersions(date: Date) async throws -> [PodcastVersion] {
        let day = podcastDay(date, calendar: .current)
        let result: PodcastVersions = try await send(request("/api/v1/daily-podcasts/versions", query: [
            .init(name: "start", value: day.start), .init(name: "end", value: day.end)
        ]))
        return result.items
    }
    /// A library podcast chip's versions, newest first.
    public func podcastVersions(summaryID: String) async throws -> [PodcastVersion] {
        let result: PodcastVersions = try await send(request("/api/v1/daily-podcasts/versions", query: [.init(name: "summaryId", value: summaryID)]))
        return result.items
    }
    public func podcastChips(date: Date) async throws -> [PodcastChip] {
        let day = podcastDay(date, calendar: .current)
        let result: PodcastChips = try await send(request("/api/v1/daily-podcasts/versions", query: [
            .init(name: "start", value: day.start), .init(name: "end", value: day.end), .init(name: "chips", value: "true")
        ]))
        return result.items
    }
    public func selectPodcast(_ podcast: DailyPodcast, date: Date) async throws {
        _ = try await podcastVersionAction(podcast, date: date, method: "PATCH")
    }
    public func removePodcast(_ podcast: DailyPodcast, date: Date) async throws {
        _ = try await podcastVersionAction(podcast, date: date, method: "DELETE")
        for language in podcast.availableLanguages { evictPodcastAudio(podcast, language: language) }
    }

    /// Removes a language's cached recording, e.g. after its version or translation is removed.
    private func evictPodcastAudio(_ podcast: DailyPodcast, language: String) {
        guard let path = podcast.audioPath, var components = URLComponents(string: path) else { return }
        var items = (components.queryItems ?? []).filter { $0.name != "language" }
        if language != podcast.sourceLanguage { items.append(URLQueryItem(name: "language", value: language)) }
        components.queryItems = items
        if let url = request(components.path, query: items).url { podcastAudioCache.remove(url.absoluteString) }
    }

    // MARK: Translations

    /// The episode in another of its languages. Never calls a model or spends points.
    public func podcastEpisode(_ podcast: DailyPodcast, language: String) async throws -> DailyPodcast {
        let day = try podcastDayBounds(podcast)
        var query = [URLQueryItem(name: "start", value: day.start), URLQueryItem(name: "end", value: day.end)]
        if language != podcast.sourceLanguage { query.append(URLQueryItem(name: "language", value: language)) }
        let result: PodcastEnvelope = try await send(request("/api/v1/daily-podcasts/\(podcast.key.urlPathEscaped)", query: query))
        guard let episode = result.podcast else { throw SummaryAPIError.invalidResponse }
        return episode
    }

    /// Speaks the episode in `language` (spends points; an existing translation is free) and returns it in that language.
    public func translatePodcast(_ podcast: DailyPodcast, language: SummaryLanguage, includeVideo: Bool = true,
                                 onProgress: (@MainActor @Sendable (PodcastGenerationProgress) -> Void)? = nil) async throws -> DailyPodcast {
        let day = try podcastDayBounds(podcast)
        var request = try json("/api/v1/daily-podcasts/\(podcast.key.urlPathEscaped)/translations", method: "POST", body: PodcastTranslationRequest(
            day: PodcastDay(start: day.start, end: day.end), language: language.rawValue, includeVideo: includeVideo
        ))
        request.timeoutInterval = 300
        if let onProgress {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            return try await receivePodcast(request, onProgress: onProgress)
        }
        let envelope: PodcastEnvelope = try await send(request)
        guard let episode = envelope.podcast else { throw SummaryAPIError.invalidResponse }
        return episode
    }

    /// Removes one translation and returns the episode in its original language.
    public func removePodcastTranslation(_ podcast: DailyPodcast, language: String) async throws -> DailyPodcast {
        let day = try podcastDayBounds(podcast)
        var remove = request("/api/v1/daily-podcasts/\(podcast.key.urlPathEscaped)/translations/\(language.urlPathEscaped)", query: [
            URLQueryItem(name: "start", value: day.start), URLQueryItem(name: "end", value: day.end)
        ])
        remove.httpMethod = "DELETE"
        let envelope = try SummaryJSON.decoder().decode(PodcastEnvelope.self, from: try await sendRaw(remove))
        evictPodcastAudio(podcast, language: language)
        guard let episode = envelope.podcast else { throw SummaryAPIError.invalidResponse }
        return episode
    }
    private func podcastVersionAction(_ podcast: DailyPodcast, date: Date, method: String) async throws -> Data {
        let fallback = podcastDay(date, calendar: .current)
        var action = request("/api/v1/daily-podcasts/\(podcast.key.urlPathEscaped)", query: [
            .init(name: "start", value: podcast.day?.start ?? fallback.start),
            .init(name: "end", value: podcast.day?.end ?? fallback.end)
        ])
        action.httpMethod = method
        return try await sendRaw(action)
    }
    public func libraryPodcast(summaryID: String) async throws -> DailyPodcast {
        let result: PodcastEnvelope = try await send(request("/api/v1/summaries/\(summaryID.urlPathEscaped)/podcast"))
        guard let podcast = result.podcast else { throw SummaryAPIError.invalidResponse }
        return podcast
    }

    public func dailyPodcastAudio(_ segment: DailyPodcast.Segment) async throws -> Data {
        // Parse query items separately: URL.appending(path:) percent-escapes '?' in a path.
        guard let path = segment.audioPath, let components = URLComponents(string: path), components.path.hasPrefix("/api/v1/daily-podcasts/") else {
            throw SummaryAPIError.invalidResponse
        }
        return try await sendRaw(request(components.path, query: components.queryItems ?? []))
    }

    /// Reuses the episode's seven-day disk cache for playback and export, downloading on a miss.
    public func dailyPodcastAudio(_ podcast: DailyPodcast) async throws -> Data {
        guard let path = podcast.audioPath, let components = URLComponents(string: path),
              components.path.hasPrefix("/api/v1/daily-podcasts/"), components.path.hasSuffix("/audio") else {
            throw SummaryAPIError.invalidResponse
        }
        var download = request(components.path, query: components.queryItems ?? [])
        download.timeoutInterval = 120
        download.cachePolicy = .reloadIgnoringLocalCacheData
        let audioRequest = download
        guard let url = audioRequest.url else { throw SummaryAPIError.invalidResponse }
        return try await podcastAudioCache.data(for: url.absoluteString) {
            try await self.sendRaw(audioRequest)
        }
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
