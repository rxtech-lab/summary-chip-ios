import Foundation
import AVFoundation
import RxRemotion
import SummaryKit
#if os(iOS)
import UIKit
#endif

enum PodcastVideoResolution: Int, CaseIterable, Identifiable, Sendable {
    case hd720 = 720, fullHD1080 = 1080, qhd1440 = 1440, ultraHD4K = 2160
    var id: Int { rawValue }
    var width: Int { rawValue * 16 / 9 }
    var height: Int { rawValue }
    var title: String { self == .ultraHD4K ? "4K (3840 × 2160)" : "\(rawValue)p (\(width) × \(height))" }
}

/// Renders an episode's agent-written Remotion composition on device: the server sends the source,
/// the app adds the recording, artwork and real timings, then WebKit draws each frame and AVFoundation
/// encodes the MP4. Matching published videos are downloaded instead. Files are cached per resolution and composition,
/// so watching, saving and publishing reuse one file.
@MainActor enum PodcastMotionRenderer {
    struct Progress: Equatable {
        enum Stage { case preparing, rendering, encoding }
        var stage: Stage
        var fraction: Double?
        var frameDetail: String?
        var transfer: MediaTransferProgress?
    }

    private static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "podcast-videos", directoryHint: .isDirectory)
    }

    /// Renders are kept per episode and language; the original keeps its earlier file names.
    private static func prefix(for podcast: DailyPodcast) -> String {
        podcast.isTranslation ? "\(podcast.key)~\(podcast.language)-" : "\(podcast.key)-"
    }

    static func cachedURL(for podcast: DailyPodcast, resolution: PodcastVideoResolution = .hd720) async throws -> URL? {
        guard let video = podcast.video else { return nil }
        let url = cache.appending(path: "\(prefix(for: podcast))\(video.id)-\(resolution.rawValue)p-subtitles-v5.mp4")
        return try await reusableVideo(at: url) ? url : nil
    }

    static func render(api: SummaryAPIClient, podcast: DailyPodcast, resolution: PodcastVideoResolution = .hd720, onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws -> URL {
        if let cached = try await cachedURL(for: podcast, resolution: resolution) { return cached }
        if let published = try await publishedVideo(api: api, podcast: podcast, resolution: resolution, onProgress: onProgress) { return published }
        guard let video = podcast.video, !podcast.segments.isEmpty else { throw SummaryAPIError.invalidResponse }
        onProgress(Progress(stage: .preparing))
        let fm = FileManager.default
        let project = fm.temporaryDirectory.appending(path: "podcast-video-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: project) }
        let source = try await api.podcastVideoSource(podcast)
        guard source.id == video.id else { throw SummaryAPIError.invalidResponse }
        try writeFiles(source.files, to: project)
        let audio = try await api.dailyPodcastAudio(podcast) { transfer in
            onProgress(Progress(stage: .preparing, fraction: transfer.fraction, transfer: transfer))
        }
        try audio.write(to: project.appending(path: "public/podcast.mp3"))
        onProgress(Progress(stage: .preparing))
        let images = try await downloadArtwork(api: api, podcast: podcast, to: project)
        try Task.checkCancellation()
        try data(podcast: podcast, source: source, images: images).write(to: project.appending(path: "src/data.json"))

        #if os(iOS)
        // WebKit stops painting in the background; keep the screen on while frames are drawn.
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        #endif
        let engine = RemotionEngine(configuration: .init(frameTimeout: 60))
        defer { engine.closeAll() }
        let prepared = try await engine.prepare(projectURL: project)
        let output = project.appending(path: "render.mp4")
        try await engine.renderMovie(project: prepared, to: output, settings: .init(width: source.width, height: source.height, codec: .h264, captureScale: Double(resolution.height) / Double(source.height))) { progress in
            switch progress.stage {
            case .preparing, .compiling: onProgress(Progress(stage: .preparing))
            case .rendering: onProgress(Progress(stage: .rendering, fraction: progress.fraction, frameDetail: progress.detail))
            case .encoding: onProgress(Progress(stage: .encoding, fraction: progress.fraction))
            }
        }
        try Task.checkCancellation()
        onProgress(Progress(stage: .encoding, fraction: 0.98))
        try PodcastVideoExporter.embedCaptions(in: output, podcast: podcast, width: resolution.width, height: resolution.height)
        try await validateVideo(at: output)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let destination = cache.appending(path: "\(prefix(for: podcast))\(video.id)-\(resolution.rawValue)p-subtitles-v5.mp4")
        if try await reusableVideo(at: destination) { return destination }
        try fm.moveItem(at: output, to: destination)
        return destination
    }

    private static func publishedVideo(api: SummaryAPIClient, podcast: DailyPodcast, resolution: PodcastVideoResolution,
                                       onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws -> URL? {
        if podcast.video?.isPublished == true {
            onProgress(Progress(stage: .preparing))
            let file = try await api.downloadPublishedPodcastVideo(podcast) { transfer in
                onProgress(Progress(stage: .preparing, fraction: transfer.fraction, transfer: transfer))
            }
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            let asset = AVURLAsset(url: file)
            let valid = try await reusableVideo(at: file)
            let track = valid ? try await asset.loadTracks(withMediaType: .video).first : nil
            let size = try await track?.load(.naturalSize)
            if size == CGSize(width: resolution.width, height: resolution.height) {
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                let destination = cache.appending(path: "\(prefix(for: podcast))\(podcast.video!.id)-\(resolution.rawValue)p-subtitles-v5.mp4")
                // Another consumer may have finished downloading while this one was suspended.
                if try await reusableVideo(at: destination) { return destination }
                try FileManager.default.moveItem(at: file, to: destination)
                return destination
            }
        }
        return nil
    }

    /// File existence alone is insufficient: interrupted writes and older exports can leave
    /// an MP4 that AVPlayer cannot open. Evict only that file and rebuild from saved source.
    static func reusableVideo(at url: URL) async throws -> Bool {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try await validateVideo(at: url)
            return true
        } catch {
            // Cancellation must never delete a healthy cache entry.
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            try FileManager.default.removeItem(at: url)
            return false
        }
    }

    static func validateVideo(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable),
              try await asset.load(.duration).seconds > 0,
              try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw SummaryAPIError.invalidResponse
        }
        // Reading metadata can succeed even when the encoded media is truncated.
        let images = AVAssetImageGenerator(asset: asset)
        _ = try await images.image(at: .zero)
        try Task.checkCancellation()
    }

    static var cacheSize: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Removes every cached render, e.g. on sign-out.
    static func clearCache() {
        try? FileManager.default.removeItem(at: cache)
    }

    static func writeFiles(_ files: [String: String], to project: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: project.appending(path: "public/art"), withIntermediateDirectories: true)
        // Physical iOS containers use /private/var aliases. Standardizing an existing directory
        // and a not-yet-created file can preserve different aliases; compare canonical paths.
        let project = project.resolvingSymlinksInPath()
        let root = project.path + "/"
        for (path, contents) in files {
            let url = project.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
            // The server owns the paths, but never let one escape the project.
            guard url.path.hasPrefix(root), path.hasPrefix("src/") else { throw SummaryAPIError.invalidResponse }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the legacy caption hook empty; only the subtitle track receives narration.
            let contents = path == "src/podcast.ts"
                ? contents.replacingOccurrences(of: "if (!segment || time > segment.endSeconds)", with: "if (!segment || !segment.caption || time > segment.endSeconds)")
                : contents
            try Data(contents.utf8).write(to: url)
        }
    }

    /// Artwork file names under public/, by the segment's image path. Missing artwork falls back to the emoji.
    private static func downloadArtwork(api: SummaryAPIClient, podcast: DailyPodcast, to project: URL) async throws -> [String: String] {
        var names: [String: String] = [:]
        for path in Set(podcast.segments.compactMap(\.imagePath)) {
            try Task.checkCancellation()
            guard let bytes = try? await api.dailyPodcastArtwork(path), !bytes.isEmpty else { continue }
            let name = "art/\(names.count).png"
            try bytes.write(to: project.appending(path: "public/\(name)"))
            names[path] = name
        }
        return names
    }

    /// `src/data.json`, matching the scaffold's `PodcastVideoData`.
    static func data(podcast: DailyPodcast, source: PodcastVideoSource, images: [String: String]) throws -> Data {
        struct Speaker: Encodable { var name: String }
        struct Segment: Encodable {
            var speaker: Int; var chipId: String; var chipTitle: String; var caption: String
            var startSeconds: Double; var endSeconds: Double; var voiceStartSeconds: Double; var voiceEndSeconds: Double
            var image: String?; var icon: String
        }
        struct Payload: Encodable {
            var title: String; var language: String; var mood: String; var durationSeconds: Double
            var fps: Double; var width: Int; var height: Int; var speakers: [Speaker]; var segments: [Segment]
        }
        let titles = Dictionary(source.chips.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let duration = podcast.durationSeconds ?? podcast.segments.compactMap(\.endSeconds).max() ?? 0
        let segments = podcast.segments.enumerated().map { index, segment in
            let start = segment.startSeconds ?? 0
            let end = segment.endSeconds ?? podcast.segments.dropFirst(index + 1).first?.startSeconds ?? duration
            return Segment(speaker: segment.speaker, chipId: segment.chipId, chipTitle: titles[segment.chipId] ?? "",
                           caption: "", startSeconds: start, endSeconds: end,
                           voiceStartSeconds: segment.voiceStartSeconds ?? start, voiceEndSeconds: segment.voiceEndSeconds ?? end,
                           image: segment.imagePath.flatMap { images[$0] }, icon: segment.icon)
        }
        let payload = Payload(title: podcast.title, language: podcast.language, mood: podcast.mood ?? "calm",
                              durationSeconds: max(1, duration), fps: source.fps, width: source.width, height: source.height,
                              speakers: podcast.speakers.map { Speaker(name: $0.name) }, segments: segments)
        return try JSONEncoder().encode(payload)
    }
}
