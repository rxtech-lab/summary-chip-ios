import Foundation

public struct PodcastPlan: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var revision: Int
    public var confirmed: Bool
    public var script: Script
    /// The refinement chat, oldest first.
    public var messages: [Message]
    /// Each segment's storyboard frame as a short-lived private URL, aligned with `script.segments`; nil when it has none.
    public var frames: [URL?]
    /// Whether the server draws storyboard frames; nil when it didn't say.
    public var storyboard: Bool?

    public struct Message: Codable, Sendable, Identifiable, Equatable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public var id: String
        public var role: Role
        public var text: String
        public var revision: Int
    }

    private enum CodingKeys: String, CodingKey { case id, revision, confirmed, script, messages, frames, storyboard }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        confirmed = try container.decode(Bool.self, forKey: .confirmed)
        script = try container.decode(Script.self, forKey: .script)
        messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
        frames = try container.decodeIfPresent([URL?].self, forKey: .frames) ?? []
        storyboard = try container.decodeIfPresent(Bool.self, forKey: .storyboard)
    }

    /// The storyboard frame of segment `index`, if drawn.
    public func frame(at index: Int) -> URL? {
        frames.indices.contains(index) ? frames[index] : nil
    }
    /// Shots that can get a frame but have none yet. The server draws frames for the first 40 shots.
    public var missingFrameCount: Int {
        guard storyboard == true else { return 0 }
        return script.segments.indices.prefix(40).filter { frame(at: $0) == nil }.count
    }
    public func speakerName(for segment: Segment) -> String {
        script.speakers.indices.contains(segment.speaker) ? script.speakers[segment.speaker].name : ""
    }
    public struct Script: Codable, Sendable, Equatable {
        public var title: String
        public var summary: String?
        public var mood: String
        public var speakers: [Speaker]
        public var segments: [Segment]
    }
    public struct Speaker: Codable, Sendable, Equatable {
        public var name: String
        public var voice: String
    }
    public struct Segment: Codable, Sendable, Equatable {
        public var speaker: Int
        public var chipId: String
        public var caption: String
        public var camera: String
    }
    public var isValid: Bool {
        Self.validText(script.title, limit: 120) && script.isSummaryValid
            && (1...4).contains(script.speakers.count)
            && (1...300).contains(script.segments.count) && script.segments.allSatisfy {
                script.speakers.indices.contains($0.speaker)
                    && Self.validText($0.caption, limit: 500)
                    && Self.validText($0.camera, limit: 2000)
            }
    }
    private static func validText(_ text: String, limit: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The server's string limits count UTF-16 code units, including emoji.
        return !trimmed.isEmpty && trimmed.utf16.count <= limit
    }
}

extension PodcastPlan.Script {
    public var isSummaryValid: Bool {
        guard let summary else { return true }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 1200 else { return false }
        var words = 0
        trimmed.enumerateSubstrings(in: trimmed.startIndex..<trimmed.endIndex, options: .byWords) { _, _, _, _ in words += 1 }
        return words < 200
    }
}
/// An unconfirmed plan as the library lists it.
public struct PodcastPlanSummary: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var revision: Int
    public var title: String
    public var summary: String?
    public var lineCount: Int
    /// A library podcast chip rather than the day's podcast.
    public var library: Bool
    public var language: String
    public var updatedAt: Date
    public var day: PodcastDayBounds?
    /// The first storyboard frame as a short-lived private URL.
    public var thumbnailUrl: URL?
}
private struct PlanEnvelope: Decodable { var plan: PodcastPlan }
private struct PlanListEnvelope: Decodable { var plans: [PodcastPlanSummary] }

extension SummaryAPIClient {
    public func preparePodcastPlan(date: Date, language: SummaryLanguage, chipIds: [String], library: Bool,
                                   includeVideo: Bool, videoStyle: PodcastVideoStyle?, summaryID: String?,
                                   speakerNames: [String]?, durationSeconds: Int?) async throws -> PodcastPlan {
        struct Body: Encodable {
            var day: PodcastDayBounds
            var language: String
            var chipIds: [String]
            var library: Bool
            var includeVideo: Bool
            var videoStyle: PodcastVideoStyle?
            var summaryId: String?
            var speakerNames: [String]?
            var durationSeconds: Int?
            var regenerate = true
        }
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let formatter = ISO8601DateFormatter()
        let body = Body(day: .init(start: formatter.string(from: start), end: formatter.string(from: end)), language: language.rawValue,
                        chipIds: chipIds, library: library, includeVideo: includeVideo, videoStyle: videoStyle,
                        summaryId: summaryID, speakerNames: speakerNames, durationSeconds: durationSeconds)
        var request = try json("/api/v1/daily-podcasts/plans", method: "POST", body: body)
        request.timeoutInterval = 120
        let response: PlanEnvelope = try await send(request)
        return response.plan
    }
    /// Revises the plan from one chat message (spends points).
    public func refinePodcastPlan(_ plan: PodcastPlan, message: String) async throws -> PodcastPlan {
        struct Body: Encodable { var revision: Int; var message: String }
        var request = try json("/api/v1/daily-podcasts/plans/\(plan.id.urlPathEscaped)/messages", method: "POST",
                               body: Body(revision: plan.revision, message: message))
        request.timeoutInterval = 180
        let response: PlanEnvelope = try await send(request)
        return response.plan
    }
    /// Draws the storyboard frames the plan's current revision is missing (spends points).
    public func drawPodcastPlanFrames(_ plan: PodcastPlan) async throws -> PodcastPlan {
        struct Body: Encodable { var revision: Int }
        var request = try json("/api/v1/daily-podcasts/plans/\(plan.id.urlPathEscaped)/frames", method: "POST", body: Body(revision: plan.revision))
        request.timeoutInterval = 300
        let response: PlanEnvelope = try await send(request)
        return response.plan
    }
    /// The owner's unconfirmed plans, most recently changed first.
    public func podcastPlans() async throws -> [PodcastPlanSummary] {
        let response: PlanListEnvelope = try await send(get("/api/v1/daily-podcasts/plans"))
        return response.plans
    }
    public func podcastPlan(id: String) async throws -> PodcastPlan {
        let response: PlanEnvelope = try await send(get("/api/v1/daily-podcasts/plans/\(id.urlPathEscaped)"))
        return response.plan
    }
    public func savedPodcast(key: String, day: PodcastDayBounds) async throws -> DailyPodcast {
        struct Envelope: Decodable { var podcast: DailyPodcast? }
        let envelope: Envelope = try await send(request("/api/v1/daily-podcasts/\(key.urlPathEscaped)", query: [
            URLQueryItem(name: "start", value: day.start), URLQueryItem(name: "end", value: day.end)
        ]))
        guard let podcast = envelope.podcast else { throw SummaryAPIError.invalidResponse }
        return podcast
    }

    /// Discards an unconfirmed plan and its storyboard frames.
    public func deletePodcastPlan(id: String) async throws {
        var request = request("/api/v1/daily-podcasts/plans/\(id.urlPathEscaped)")
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }
    public func revisePodcastPlan(_ plan: PodcastPlan) async throws -> PodcastPlan {
        struct Body: Encodable { var revision: Int; var script: PodcastPlan.Script }
        let response: PlanEnvelope = try await send(json("/api/v1/daily-podcasts/plans/\(plan.id.urlPathEscaped)", method: "PATCH",
                                                       body: Body(revision: plan.revision, script: plan.script)))
        return response.plan
    }
    public func confirmPodcastPlan(_ plan: PodcastPlan,
                                   onProgress: @escaping @MainActor @Sendable (PodcastGenerationProgress) -> Void) async throws -> DailyPodcast {
        struct Body: Encodable { var revision: Int }
        var request = try json("/api/v1/daily-podcasts/plans/\(plan.id.urlPathEscaped)", method: "POST", body: Body(revision: plan.revision))
        request.timeoutInterval = 300
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return try await receivePodcast(request, onProgress: onProgress)
    }
}
