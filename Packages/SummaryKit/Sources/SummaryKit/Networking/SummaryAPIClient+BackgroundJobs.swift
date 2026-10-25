import Foundation

public struct BackgroundJob: Decodable, Sendable, Identifiable, Equatable {
    public struct Failure: Decodable, Sendable, Equatable {
        public var code: String
        public var message: String
    }
    public struct Log: Decodable, Sendable, Identifiable, Equatable {
        public var id: String
        public var at: Date
        public var message: String
    }
    public var id: String
    public var title: String
    public var episodeKey: String
    public var day: PodcastDayBounds
    public var language: String?
    public var status: String
    public var videoId: String?
    public var percent: Int
    public var error: Failure?
    public var createdAt: Date
    public var updatedAt: Date
    public var logs: [Log]
}

public struct BackgroundJobPage: Decodable, Sendable {
    public var items: [BackgroundJob]
    public var nextCursor: String?
}
private struct BackgroundJobEnvelope: Decodable { var job: BackgroundJob }
private struct BackgroundEpisodeEnvelope: Decodable { var podcast: DailyPodcast }

extension SummaryAPIClient {
    public func backgroundJobs(cursor: String? = nil) async throws -> BackgroundJobPage {
        try await send(request("/api/v1/background-jobs", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []))
    }

    public func backgroundJob(id: String) async throws -> BackgroundJob {
        let result: BackgroundJobEnvelope = try await send(request("/api/v1/background-jobs/\(id.urlPathEscaped)"))
        return result.job
    }

    public func backgroundJobPodcast(_ job: BackgroundJob) async throws -> DailyPodcast {
        var query = [URLQueryItem(name: "start", value: job.day.start), URLQueryItem(name: "end", value: job.day.end)]
        if let language = job.language { query.append(URLQueryItem(name: "language", value: language)) }
        let result: BackgroundEpisodeEnvelope = try await send(request("/api/v1/daily-podcasts/\(job.episodeKey.urlPathEscaped)", query: query))
        return result.podcast
    }
}
