import Foundation

/// A voice an audiobook speaker can use. Its id says which provider speaks it.
public struct AudiobookVoice: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var provider: String
    public var name: String
    public var gender: String
    public var description: String
    public var providerTitle: String { provider == "azure" ? "Azure" : "ElevenLabs" }
}

/// `GET /api/v1/audiobooks/options`: what the audiobook form offers, localized by the server.
public struct AudiobookOptions: Decodable, Sendable, Equatable {
    public struct Length: Decodable, Sendable, Equatable, Identifiable {
        /// Nil narrates the whole source.
        public var seconds: Int?
        public var title: String
        public var id: Int { seconds ?? 0 }
    }
    public var voices: [AudiobookVoice]
    public var languages: [SummaryLanguage]
    public var themes: [PodcastGenerationOptions.VideoStyle]
    public var defaultTheme: PodcastVideoStyle
    public var speakers: PodcastGenerationOptions.Speakers
    public var lengths: [Length]
    /// Whether scenes can be illustrated.
    public var video: Bool

    public func voice(_ id: String) -> AudiobookVoice? { voices.first { $0.id == id } }
    public func theme(_ id: PodcastVideoStyle) -> PodcastGenerationOptions.VideoStyle? { themes.first { $0.id == id } }

    enum CodingKeys: String, CodingKey { case voices, languages, themes, defaultTheme, speakers, lengths, video }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        voices = try container.decode([AudiobookVoice].self, forKey: .voices)
        languages = try container.decode([String].self, forKey: .languages).compactMap { SummaryLanguage(rawValue: $0) }
        themes = try container.decode([PodcastGenerationOptions.VideoStyle].self, forKey: .themes)
        defaultTheme = try container.decode(PodcastVideoStyle.self, forKey: .defaultTheme)
        speakers = try container.decode(PodcastGenerationOptions.Speakers.self, forKey: .speakers)
        lengths = try container.decode([Length].self, forKey: .lengths)
        video = try container.decode(Bool.self, forKey: .video)
    }
}

/// The reviewable plan: chat and the editors change it before any media is made.
public struct AudiobookPlan: Decodable, Sendable, Identifiable, Equatable {
    public struct Document: Codable, Sendable, Equatable {
        public var title: String
        public var summary: String
        public var speakers: [Speaker]
        public var musicCues: [MusicCue]
        public var visualGuide: String
        public var videoTheme: PodcastVideoStyle
        public var chapters: [Chapter]
    }
    public struct Speaker: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var voice: String
        public var role: String
        public var id: String { voice }
        public init(name: String, voice: String, role: String = "") { self.name = name; self.voice = voice; self.role = role }
    }
    public struct MusicCue: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var prompt: String
        public var mood: String
    }
    public struct Scene: Codable, Sendable, Equatable {
        public var prompt: String
        public var motion: String
        public init(prompt: String, motion: String) { self.prompt = prompt; self.motion = motion }
    }
    public struct Chapter: Codable, Sendable, Equatable {
        public var title: String
        public var synopsis: String
        public var firstPassage: Int
        public var lastPassage: Int
        public var music: [String]
        public var scenes: [Scene]
    }
    public struct Estimate: Decodable, Sendable, Equatable {
        public var seconds: Int
        public var characters: Int
        public var points: Int
    }
    public var id: String
    public var revision: Int
    public var confirmed: Bool
    public var plan: Document
    public var messages: [PodcastPlan.Message]
    /// Scene images as short-lived private links, by chapter and scene; nil until drawn.
    public var frames: [[URL?]]
    public var language: String
    public var includeVideo: Bool
    public var day: PodcastDayBounds
    public var canDrawFrames: Bool
    public var estimate: Estimate

    public func frame(chapter: Int, scene: Int) -> URL? {
        guard frames.indices.contains(chapter), frames[chapter].indices.contains(scene) else { return nil }
        return frames[chapter][scene]
    }
    /// Scenes within the review's limit with no image yet.
    public var missingFrameCount: Int {
        guard canDrawFrames else { return 0 }
        return plan.chapters.flatMap(\.scenes).prefix(24).count - frames.flatMap { $0 }.compactMap { $0 }.count
    }
    public func musicTitles(for chapter: Chapter) -> [String] {
        chapter.music.compactMap { id in plan.musicCues.first { $0.id == id }?.title }
    }
}

public struct AudiobookPlanSummary: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var chapterCount: Int
    public var updatedAt: Date
    public var thumbnailUrl: URL?
}

/// A generation or translation running in the background.
public struct AudiobookJob: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: String
    public var status: String
    public var stage: String
    public var percent: Int
    public var planId: String?
    public var episodeKey: String
    public var language: String
    public var day: PodcastDayBounds
    public var title: String
    public var completedChapters: Int
    public var totalChapters: Int
    public var summaryId: String?
    public var error: APIErrorBody?

    public var isRunning: Bool { status == "running" }
    public var isReady: Bool { status == "ready" }
    public var isFailed: Bool { status == "failed" }
    public var fraction: Double { Double(min(100, max(0, percent))) / 100 }
    public var stageTitle: String {
        switch stage {
        case "music": String(localized: "Composing the soundtrack…", bundle: .module)
        case "writing": String(localized: "Writing the narration…", bundle: .module)
        case "voicing": String(localized: "Recording the voices…", bundle: .module)
        case "mixing": String(localized: "Mixing voices and music…", bundle: .module)
        case "saving": String(localized: "Saving your audiobook…", bundle: .module)
        case "complete": String(localized: "Audiobook ready", bundle: .module)
        default: String(localized: "Getting ready…", bundle: .module)
        }
    }
}

private struct AudiobookPlanEnvelope: Decodable { var plan: AudiobookPlan }
private struct AudiobookJobEnvelope: Decodable { var job: AudiobookJob }

extension SummaryAPIClient {
    public func followAudiobookJob(_ initial: AudiobookJob, onProgress: @MainActor (AudiobookJob) -> Void) async throws -> AudiobookJob {
        var current = initial
        await onProgress(current)
        while current.isRunning {
            try await Task.sleep(for: .seconds(2))
            current = try await audiobookJob(id: current.id)
            try Task.checkCancellation()
            await onProgress(current)
        }
        return current
    }

    public func audiobookOptions() async throws -> AudiobookOptions {
        try await send(request("/api/v1/audiobooks/options"))
    }

    /// A short-lived link to a voice's sample. The server draws it once and then serves it from storage.
    public func audiobookVoiceSample(voice: String, language: SummaryLanguage) async throws -> URL {
        struct Sample: Decodable { var url: URL }
        var sample = request("/api/v1/audiobooks/voices/sample", query: [.init(name: "voice", value: voice), .init(name: "language", value: language.rawValue)])
        sample.timeoutInterval = 60
        let result: Sample = try await send(sample)
        return result.url
    }

    /// Reads the sources and drafts the plan (spends points). With `planMode` off the plan is confirmed and its job returned.
    public func createAudiobook(date: Date, language: SummaryLanguage, chipIds: [String], speakers: [AudiobookPlan.Speaker]?, includeVideo: Bool,
                                videoTheme: PodcastVideoStyle?, targetSeconds: Int?, summaryID: String?, planMode: Bool) async throws -> (plan: AudiobookPlan, job: AudiobookJob?) {
        struct Speaker: Encodable { var name: String; var voice: String }
        struct Body: Encodable {
            var day: PodcastDayBounds; var language: String; var chipIds: [String]; var speakers: [Speaker]?; var includeVideo: Bool
            var videoTheme: PodcastVideoStyle?; var targetSeconds: Int?; var summaryId: String?; var planMode: Bool
        }
        struct Response: Decodable { var plan: AudiobookPlan; var job: AudiobookJob? }
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let formatter = ISO8601DateFormatter()
        var create = try json("/api/v1/audiobooks", method: "POST", body: Body(
            day: .init(start: formatter.string(from: start), end: formatter.string(from: end)), language: language.rawValue, chipIds: chipIds,
            speakers: speakers?.map { Speaker(name: $0.name, voice: $0.voice) }, includeVideo: includeVideo, videoTheme: videoTheme, targetSeconds: targetSeconds,
            summaryId: summaryID, planMode: planMode))
        create.timeoutInterval = 300
        let response: Response = try await send(create)
        return (response.plan, response.job)
    }

    /// The owner's unconfirmed plans, and audiobooks being made or needing attention.
    public func audiobookLibrary() async throws -> (plans: [AudiobookPlanSummary], jobs: [AudiobookJob]) {
        struct Response: Decodable { var plans: [AudiobookPlanSummary]; var jobs: [AudiobookJob] }
        let response: Response = try await send(request("/api/v1/audiobooks/plans"))
        return (response.plans, response.jobs)
    }
    public func audiobookPlan(id: String) async throws -> AudiobookPlan {
        let response: AudiobookPlanEnvelope = try await send(request("/api/v1/audiobooks/plans/\(id.urlPathEscaped)"))
        return response.plan
    }
    /// Saves edits to speakers, voices, chapters, music, scenes or the video theme.
    public func reviseAudiobookPlan(_ plan: AudiobookPlan, document: AudiobookPlan.Document) async throws -> AudiobookPlan {
        struct Body: Encodable { var revision: Int; var plan: AudiobookPlan.Document }
        let response: AudiobookPlanEnvelope = try await send(json("/api/v1/audiobooks/plans/\(plan.id.urlPathEscaped)", method: "PATCH", body: Body(revision: plan.revision, plan: document)))
        return response.plan
    }
    /// Revises the plan from one chat message (spends points).
    public func refineAudiobookPlan(_ plan: AudiobookPlan, message: String) async throws -> AudiobookPlan {
        struct Body: Encodable { var revision: Int; var message: String }
        var refine = try json("/api/v1/audiobooks/plans/\(plan.id.urlPathEscaped)/messages", method: "POST", body: Body(revision: plan.revision, message: message))
        refine.timeoutInterval = 300
        let response: AudiobookPlanEnvelope = try await send(refine)
        return response.plan
    }
    /// Draws the scene images the plan is missing (spends points). The video reuses them.
    public func drawAudiobookPlanFrames(_ plan: AudiobookPlan) async throws -> AudiobookPlan {
        struct Body: Encodable { var revision: Int }
        var draw = try json("/api/v1/audiobooks/plans/\(plan.id.urlPathEscaped)/frames", method: "POST", body: Body(revision: plan.revision))
        draw.timeoutInterval = 300
        let response: AudiobookPlanEnvelope = try await send(draw)
        return response.plan
    }
    /// Confirms the reviewed revision, or retries after a failure, continuing from the saved chapters.
    public func confirmAudiobookPlan(id: String, revision: Int, chapters: [Int]? = nil) async throws -> AudiobookJob {
        struct Body: Encodable { var revision: Int; var chapters: [Int]? }
        let response: AudiobookJobEnvelope = try await send(json("/api/v1/audiobooks/plans/\(id.urlPathEscaped)", method: "POST", body: Body(revision: revision, chapters: chapters)))
        return response.job
    }
    public func deleteAudiobookPlan(id: String) async throws {
        var remove = request("/api/v1/audiobooks/plans/\(id.urlPathEscaped)")
        remove.httpMethod = "DELETE"
        _ = try await sendRaw(remove)
    }
    public func audiobookJob(id: String) async throws -> AudiobookJob {
        let response: AudiobookJobEnvelope = try await send(request("/api/v1/audiobooks/jobs/\(id.urlPathEscaped)"))
        return response.job
    }
    public func dismissAudiobookJob(id: String) async throws {
        var remove = request("/api/v1/audiobooks/jobs/\(id.urlPathEscaped)")
        remove.httpMethod = "DELETE"
        _ = try await sendRaw(remove)
    }
    /// Starts speaking a saved audiobook in another language; progress is read from the returned job.
    public func translateAudiobook(key: String, day: PodcastDayBounds, language: String, includeVideo: Bool) async throws -> AudiobookJob {
        struct Body: Encodable { var day: PodcastDayBounds; var language: String; var includeVideo: Bool }
        let response: AudiobookJobEnvelope = try await send(json("/api/v1/audiobooks/\(key.urlPathEscaped)/translations", method: "POST",
            body: Body(day: day, language: language, includeVideo: includeVideo)))
        return response.job
    }

    /// Whole books are too large to pass through the API, so they download straight from storage with a short-lived link.
    func downloadAudiobookRecording(path: String, query: [URLQueryItem], onProgress: MediaTransferProgress.Handler?) async throws -> Data {
        struct Link: Decodable { var url: URL; var byteSize: Int? }
        let link: Link = try await send(request("\(path)/link", query: query))
        var download = URLRequest(url: link.url)
        download.timeoutInterval = 600
        await onProgress?(.init(completedBytes: 0, totalBytes: link.byteSize.map(Int64.init)))
        let delegate = onProgress.map { MediaTransferDelegate($0) }
        let (file, response) = try await session.download(for: download, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SummaryAPIError.invalidResponse }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }
}
