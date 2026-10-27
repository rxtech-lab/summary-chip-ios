import Foundation
import Testing
@testable import SummaryKit

@Suite(.serialized) struct DailyPodcastTests {
    @Test @MainActor func backfillsSummaryWithBillingProofAndEpisodeBounds() async throws {
        PodcastProtocol.recorder.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config), billingProofProvider: { .xcode })
        let podcast = try await api.generateDailyPodcast(date: .now, language: .en, regenerate: false)
        let result = try await api.generatePodcastSummary(podcast)
        #expect(result.summary == "Recorded story overview.")
        #expect(result.audioPath == podcast.audioPath)
        let request = try #require(PodcastProtocol.recorder.values.last)
        #expect(request.url?.path == "/api/v1/daily-podcasts/key/summary")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-storekit-environment") == "xcode")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
        #expect(body["language"] as? String == podcast.language)
        #expect((body["day"] as? [String: String])?["start"] == "2030-03-10T05:00:00Z")
    }

    @Test func podcastTypesDecodeAndRoundTripWithLegacyFallback() throws {
        let json = #"{"key":"type-test","title":"Recap","language":"en","createdAt":"2030-03-10T05:00:00Z","speakers":[],"segments":[]}"#
        var episode = try SummaryJSON.decoder().decode(DailyPodcast.self, from: Data(json.utf8))
        #expect(episode.summary == nil)
        episode.summary = "The main stories and their takeaways."
        let saved = try JSONEncoder().encode(episode)
        #expect(try JSONDecoder().decode(DailyPodcast.self, from: saved).summary == episode.summary)
        #expect(episode.resolvedType == .daily)
        episode.summaryId = "library-chip"
        #expect(episode.resolvedType == .regular)
        for type in [DailyPodcast.PodcastType.daily, .regular] {
            episode.type = type
            let data = try JSONEncoder().encode(episode)
            #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String == type.rawValue)
            #expect(try JSONDecoder().decode(DailyPodcast.self, from: data).resolvedType == type)
        }
    }

    @Test @MainActor func usesLocalDayBoundariesAndCarriesBillingProofOnlyForGeneration() async throws {
        PodcastProtocol.recorder.clear()
        let cacheFolder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheFolder) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config), billingProofProvider: { .xcode },
                                   podcastAudioCache: PodcastAudioCache(directory: cacheFolder))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let date = calendar.date(from: DateComponents(year: 2030, month: 3, day: 10, hour: 12))!
        #expect(try await api.dailyPodcast(date: date, calendar: calendar) == nil)
        let podcast = try await api.generateDailyPodcast(date: date, language: .zhHant, regenerate: true, calendar: calendar)
        #expect(podcast.language == "zh-Hant")
        #expect(try await api.dailyPodcastAudio(podcast) == Data("audio".utf8))
        // A cached export completes its progress without another HTTP request.
        var transfers: [MediaTransferProgress] = []
        #expect(try await api.dailyPodcastAudio(podcast, onProgress: { transfers.append($0) }) == Data("audio".utf8))
        #expect(transfers == [.init(completedBytes: 5, totalBytes: 5)])
        let requests = PodcastProtocol.recorder.values
        #expect(requests.count == 3)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: query.first { $0.name == "start" }!.value!)!
        let end = formatter.date(from: query.first { $0.name == "end" }!.value!)!
        #expect(end.timeIntervalSince(start) == 23 * 3_600)
        #expect(requests[0].value(forHTTPHeaderField: "x-storekit-environment") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "x-storekit-environment") == "xcode")
        #expect(requests[1].timeoutInterval == 300)
        #expect(requests[2].url?.path == "/api/v1/daily-podcasts/key/audio")
        #expect(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "2030-03-10T05:00:00Z")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer podcast-token" })
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        #expect(body["language"] as? String == "zh-Hant")
        #expect(body["regenerate"] as? Bool == true)
    }

    @Test @MainActor func receivesStreamedProgressAndCompletion() async throws {
        PodcastProtocol.recorder.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://stream.podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config), billingProofProvider: { .xcode })
        var updates: [PodcastGenerationProgress] = []
        let podcast = try await api.generateDailyPodcast(date: .now, language: .en, regenerate: true,
                                                        onProgress: { updates.append($0) })
        #expect(podcast.key == "key")
        #expect(updates.map(\.percent) == [0, 45, 100])
        #expect(updates[1].completedSegments == 1)
        #expect(updates[1].totalSegments == 2)
        #expect(PodcastProtocol.recorder.values.count == 1)
        #expect(PodcastProtocol.recorder.values[0].value(forHTTPHeaderField: "x-storekit-environment") == "xcode")
    }

    @Test @MainActor func videoDesignStartsOnTheServerAndIsFollowedByPolling() async throws {
        PodcastProtocol.recorder.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://design.podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config), billingProofProvider: { .xcode })
        let initial = try await api.generateDailyPodcast(date: .now, language: .en, regenerate: true)
        let started = try await api.composePodcastVideo(initial)
        #expect(started.isDesigningVideo)
        #expect(started.video == nil)
        let request = PodcastProtocol.recorder.values.last!
        #expect(request.url?.path == "/api/v1/daily-podcasts/key/video")
        // The design runs in the background: no streamed response to keep open.
        #expect(request.value(forHTTPHeaderField: "Accept") != "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "x-storekit-environment") == "xcode")
        var progress: [Int] = []
        let finished = try await api.waitForPodcastVideoDesign(started, interval: .milliseconds(10), onProgress: { progress.append($0.percent) })
        #expect(progress == [42])
        #expect(finished.video?.id == "video-2")
        #expect(!finished.isDesigningVideo)
        #expect(PodcastProtocol.recorder.values.last?.httpMethod == "GET")
    }

    @Test @MainActor func failedVideoDesignThrowsTheServerError() async throws {
        PodcastProtocol.recorder.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://designfail.podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config))
        let started = try await api.composePodcastVideo(try await api.generateDailyPodcast(date: .now, language: .en, regenerate: true))
        do {
            _ = try await api.waitForPodcastVideoDesign(started, interval: .milliseconds(10))
            Issue.record("A failed design must throw")
        } catch let error as SummaryAPIError {
            guard case .server(_, let body) = error else { Issue.record("Expected server error"); return }
            #expect(body.code == "PODCAST_VIDEO_FAILED")
        }
    }

    @Test func interruptedAndFailedStreamsNeverRetry() async throws {
        for host in ["interrupted.podcast.test", "failed.podcast.test"] {
            PodcastProtocol.recorder.clear()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [PodcastProtocol.self]
            let api = SummaryAPIClient(baseURL: URL(string: "https://\(host)")!, tokenProvider: PodcastToken(),
                                       session: URLSession(configuration: config))
            do {
                _ = try await api.generateDailyPodcast(date: .now, language: .en, regenerate: true, onProgress: { _ in })
                Issue.record("An incomplete stream must fail")
            } catch let error as SummaryAPIError {
                if host.hasPrefix("failed") {
                    guard case .server(let status, let body) = error else { Issue.record("Expected server error"); return }
                    #expect(status == 502)
                    #expect(body.code == "PODCAST_FAILED")
                } else { #expect(error == .invalidResponse) }
            }
            #expect(PodcastProtocol.recorder.values.count == 1)
        }
    }

    @Test func streamingRequestAcceptsLegacyJSONWithoutResubmitting() async throws {
        PodcastProtocol.recorder.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config))
        let podcast = try await api.generateDailyPodcast(date: .now, language: .en, regenerate: true, onProgress: { _ in })
        #expect(podcast.key == "key")
        #expect(PodcastProtocol.recorder.values.count == 1)
    }

    @Test func sendsExplicitChipSelectionForLibraryPodcast() async throws {
        PodcastProtocol.recorder.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config))
        _ = try await api.generateDailyPodcast(date: .now, language: .en, regenerate: true,
                                               chipIds: ["older-chip", "today-chip"], library: true, includeVideo: false, speakerNames: ["小明", "Jane"])
        let body = try JSONSerialization.jsonObject(with: PodcastProtocol.recorder.values[0].httpBody!) as! [String: Any]
        #expect(body["chipIds"] as? [String] == ["older-chip", "today-chip"])
        #expect(body["library"] as? Bool == true)
        #expect(body["includeVideo"] as? Bool == false)
        #expect(body["speakerNames"] as? [String] == ["小明", "Jane"])
        #expect(body["regenerate"] as? Bool == true)
    }

    @Test func translationsAndLibraryVersionsUseEpisodeDayAndLanguage() async throws {
        PodcastProtocol.recorder.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config))
        let podcast = try await api.generateDailyPodcast(date: .now, language: .en, regenerate: true, library: true, summaryID: "podcast-chip")
        #expect(!podcast.isTranslation)
        #expect(podcast.availableLanguages == ["zh-Hant"])
        _ = try await api.translatePodcast(podcast, language: .ja, includeVideo: false)
        _ = try await api.podcastEpisode(podcast, language: "ja")
        var translated = podcast
        translated.originalLanguage = "zh-Hant"
        translated.language = "ja"
        #expect(translated.isTranslation)
        _ = try await api.composePodcastVideo(podcast)
        _ = try await api.composePodcastVideo(translated)
        let requests = PodcastProtocol.recorder.values
        let body = { (index: Int) in try JSONSerialization.jsonObject(with: requests[index].httpBody!) as! [String: Any] }
        #expect(try body(0)["summaryId"] as? String == "podcast-chip")
        #expect(requests[1].url?.path == "/api/v1/daily-podcasts/key/translations")
        #expect(try body(1)["language"] as? String == "ja")
        #expect(try body(1)["includeVideo"] as? Bool == false)
        #expect((try body(1)["day"] as? [String: String])?["start"] == "2030-03-10T05:00:00Z")
        let query = URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(requests[2].url?.path == "/api/v1/daily-podcasts/key")
        #expect(query.first { $0.name == "language" }?.value == "ja")
        // The original's video requests are unchanged; a translation names its language.
        #expect(try body(3)["language"] == nil)
        #expect(try body(4)["language"] as? String == "ja")
    }

    @Test func shareLinksUseEpisodeDayAndSendOnlyNameAndLifetime() async throws {
        PodcastProtocol.recorder.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastProtocol.self]
        let api = SummaryAPIClient(baseURL: URL(string: "https://podcast.test")!, tokenProvider: PodcastToken(),
                                   session: URLSession(configuration: config))
        let podcast = try await api.generateDailyPodcast(date: .now, language: .en, regenerate: false)
        #expect(try await api.podcastShareLinks(key: podcast.key).isEmpty)
        let created = try await api.createPodcastShareLink(podcast, changes: ShareLinkChanges(label: "Family", access: .anyone, ttl: .never, emails: []))
        #expect(created.access == .anyone)
        #expect(created.url.lastPathComponent == "abcdefghijkl")
        _ = try await api.updatePodcastShareLink(key: podcast.key, linkID: created.id, changes: ShareLinkChanges(label: "Team"))
        _ = try await api.updatePodcastShareLink(key: podcast.key, linkID: created.id, changes: ShareLinkChanges(ttl: .days(30)))
        try await api.deletePodcastShareLink(key: podcast.key, linkID: created.id)
        let requests = PodcastProtocol.recorder.values.filter { $0.url!.path.contains("/links") }
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "PATCH", "PATCH", "DELETE"])
        #expect(requests[1].url?.path == "/api/v1/daily-podcasts/key/links")
        #expect(requests[4].url?.path == "/api/v1/daily-podcasts/key/links/link-1")
        let bodies = try requests[1...3].map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] }
        // Podcast links are always open to anyone, so access and emails are never sent.
        #expect(Set(bodies[0].keys) == ["day", "label", "ttlDays"])
        #expect(bodies[0]["ttlDays"] is NSNull)
        let day = bodies[0]["day"] as! [String: String]
        #expect(day["start"] == "2030-03-10T05:00:00Z")
        #expect(day["end"] == "2030-03-11T04:00:00Z")
        #expect(Set(bodies[1].keys) == ["label"])
        #expect(Set(bodies[2].keys) == ["ttlDays"])
        #expect(bodies[2]["ttlDays"] as? Int == 30)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer podcast-token" })
    }
}

private struct PodcastToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "podcast-token" }
}
private final class PodcastRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
    func clear() { lock.withLock { storage = [] } }
}
private final class PodcastProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = PodcastRecorder()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("podcast.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = body
        }
        Self.recorder.append(recorded)
        var body: String
        let path = request.url!.path
        if path.contains("/links") {
            let link = #"{"id":"link-1","url":"https://podcast.test/podcast/abcdefghijkl","label":null,"access":"anyone","ttlDays":7,"expiresAt":null,"isExpired":false,"emails":[],"createdAt":"2030-03-10T05:00:00Z","updatedAt":"2030-03-10T05:00:00Z"}"#
            switch request.httpMethod {
            case "GET": body = #"{"items":[]}"#
            case "DELETE": body = ""
            default: body = link
            }
        } else if request.url!.path.hasSuffix("/audio") { body = "audio" }
        else if request.httpMethod == "POST" || request.url!.path == "/api/v1/daily-podcasts/key" {
            body = #"{"podcast":{"key":"key","title":"Daily","language":"zh-Hant","createdAt":"2030-03-10T05:00:00Z","durationSeconds":2,"audioPath":"/api/v1/daily-podcasts/key/audio?start=2030-03-10T05%3A00%3A00Z&end=2030-03-11T04%3A00%3A00Z","speakers":[{"name":"Alex","voice":"voice"}],"segments":[{"speaker":0,"chipId":"one","caption":"Hello","audioPath":"/api/v1/daily-podcasts/key/audio?start=2030-03-10T05%3A00%3A00Z&end=2030-03-11T04%3A00%3A00Z","imagePath":null,"icon":"🎙️"}]}}"#
        } else { body = #"{"podcast":null}"# }
        if request.url!.host!.hasPrefix("design"), body.hasPrefix(#"{"podcast":{"#) {
            // A started design, then on the next read either the new video or the run's failure.
            let now = ISO8601DateFormatter().string(from: Date())
            let fields: String
            if request.httpMethod == "POST" && path.hasSuffix("/video") {
                fields = #""videoDesign":{"id":"design-1","startedAt":"\#(now)","updatedAt":"\#(now)","percent":42},"#
            } else if request.httpMethod == "GET" {
                fields = request.url!.host!.hasPrefix("designfail")
                    ? #""videoDesign":{"id":"design-1","startedAt":"\#(now)","updatedAt":"\#(now)","percent":42,"error":{"code":"PODCAST_VIDEO_FAILED","message":"The video could not be designed."}},"#
                    : #""video":{"id":"video-2","createdAt":"\#(now)"},"#
            } else { fields = "" }
            body = #"{"podcast":{"# + fields + body.dropFirst(#"{"podcast":{"#.count)
        }
        if path.hasSuffix("/summary") {
            body = body.replacingOccurrences(of: #""title":"Daily""#, with: #""title":"Daily","summary":"Recorded story overview.""#)
        }
        var payload = body
        var headers = ["Content-Type": "application/json"]
        if request.url?.host != "podcast.test", request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
            headers["Content-Type"] = "text/event-stream"
            payload = ": keepalive\n\ndata: {\"type\":\"progress\",\"progress\":{\"stage\":\"preparing\",\"percent\":0}}\n\n"
            if request.url?.host == "stream.podcast.test" {
                payload += "data: {\"type\":\"progress\",\"progress\":{\"stage\":\"speech\",\"percent\":45,\"completedSegments\":1,\"totalSegments\":2}}\n\n"
                payload += "data: {\"type\":\"progress\",\"progress\":{\"stage\":\"complete\",\"percent\":100}}\n\n"
                payload += "data: {\"type\":\"complete\"," + body.dropFirst() + "\n\n"
            } else if request.url?.host == "failed.podcast.test" {
                payload += "data: {\"type\":\"error\",\"status\":502,\"error\":{\"code\":\"PODCAST_FAILED\",\"message\":\"Generation failed\"}}\n\n"
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
