import AVFoundation
import Foundation
import RxRemotion
import SummaryKit
import Testing
@testable import summary_chip

@MainActor @Suite struct PodcastMediaTests {
    @Test func removesUnreadableCachedVideo() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "broken-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("truncated movie".utf8).write(to: file)
        #expect(try await !PodcastMotionRenderer.reusableVideo(at: file))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await !PodcastMotionRenderer.reusableVideo(at: file))
    }

    @Test func resumesInterruptedPlaybackAtTheSamePosition() {
        let player = interruptionPlayer()
        defer { player.stop() }
        player.duration = 100
        player.currentTime = 42
        player.playing = true
        player.beginInterruption()
        #expect(player.interrupted)
        #expect(!player.playing)
        // Repeated notifications must preserve the original playback intent.
        player.beginInterruption()
        player.endInterruption(shouldResume: true)
        #expect(!player.interrupted)
        #expect(player.playing)
        #expect(player.currentTime == 42)
    }

    @Test func doesNotResumePausedPlaybackOrWhenSystemDeniesResume() {
        let player = interruptionPlayer()
        defer { player.stop() }
        player.beginInterruption()
        player.endInterruption(shouldResume: true)
        #expect(!player.playing)
        player.playing = true
        player.beginInterruption()
        player.endInterruption(shouldResume: false)
        #expect(!player.playing)
        player.endInterruption(shouldResume: true)
        #expect(!player.playing)
    }

    @Test func explicitPauseOrCloseCancelsInterruptionRecovery() {
        let player = interruptionPlayer()
        player.playing = true
        player.beginInterruption()
        player.pause()
        player.endInterruption(shouldResume: true)
        #expect(!player.playing)
        player.playing = true
        player.beginInterruption()
        player.close()
        player.endInterruption(shouldResume: true)
        #expect(!player.playing)
        #expect(player.podcast == nil)
    }

    private func interruptionPlayer() -> DailyPodcastPlayer {
        // No episode is loaded: exercise interruption intent without opening the
        // simulator audio device or fetching media.
        DailyPodcastPlayer(api: SummaryAPIClient(baseURL: URL(string: "https://example.invalid")!, tokenProvider: MediaTestToken()))
    }

    @Test func writesVideoFilesThroughPrivateDirectoryAlias() throws {
        #if os(macOS) || targetEnvironment(simulator)
        // Use the app's writable temporary directory while still exercising /var's
        // /private/var alias; sandboxed macOS tests cannot write to /private/tmp.
        let canonical = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let temporary = URL(fileURLWithPath: canonical.hasPrefix("/private/") ? String(canonical.dropFirst(8)) : canonical,
                            isDirectory: true)
        #else
        let temporary = FileManager.default.temporaryDirectory
        #endif
        let project = temporary.appending(path: "podcast-path-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        let files = ["src/index.ts": "import './Root';", "src/scenes/Scene.tsx": "export const Scene = () => null;"]
        try PodcastMotionRenderer.writeFiles(files, to: project)
        for (path, contents) in files {
            #expect(try String(contentsOf: project.appending(path: path), encoding: .utf8) == contents)
        }
    }

    @Test func rejectsVideoFilesOutsideProject() throws {
        let project = FileManager.default.temporaryDirectory.appending(path: "podcast-path-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: project) }
        for path in ["src/../../escape.ts", "outside.ts"] {
            #expect(throws: SummaryAPIError.invalidResponse) {
                try PodcastMotionRenderer.writeFiles([path: "invalid"], to: project)
            }
        }
    }

    @Test func exportsStandaloneCaptionsWithTimestampsAndNoPunctuation() throws {
        let podcast = try SummaryJSON.decoder().decode(DailyPodcast.self, from: Data(#"""
        {"key":"test","title":"Captions","language":"en","createdAt":"2030-03-10T05:00:00Z",
        "speakers":[{"name":"Alex","voice":"fixture"}],
        "segments":[{"speaker":0,"chipId":"one","caption":"Hello, 世界! Here's news.","icon":"",
        "captionCues":[{"text":"Hello, 世界!","startSeconds":1.25,"endSeconds":2.5},
        {"text":"Here's news.","startSeconds":3661.001,"endSeconds":3663.125}]}]}
        """#.utf8))
        let text = String(decoding: try PodcastVideoExporter.subtitleData(for: podcast), as: UTF8.self)
        #expect(text == "1\n00:00:01,250 --> 00:00:02,500\nHello 世界\n\n2\n01:01:01,001 --> 01:01:03,125\nHeres news\n")
    }

    @Test(arguments: PodcastVideoResolution.allCases)
    func rendersMotionCompositionWithRecordedAudio(resolution: PodcastVideoResolution) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "motion-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try wave().write(to: folder.appending(path: "public/voice.wav"))
        let source = #"""
        import React from 'react';
        import {registerRoot, Composition, AbsoluteFill, Audio, staticFile, useCurrentFrame} from 'remotion';
        const Clip = () => {
          const frame = useCurrentFrame();
          return <AbsoluteFill style={{backgroundColor: frame < 6 ? 'red' : 'blue'}}>
            <Audio src={staticFile('voice.wav')} />
          </AbsoluteFill>;
        };
        registerRoot(() => <Composition id="Main" component={Clip} durationInFrames={12} fps={12} width={1280} height={720} />);
        """#
        try Data(source.utf8).write(to: folder.appending(path: "src/index.tsx"))
        let engine = RemotionEngine()
        defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: folder, entryPoint: "src/index.tsx")
        let output = folder.appending(path: "motion.mp4")
        try await engine.renderMovie(project: project, to: output, settings: .init(codec: .h264, concurrency: 1, captureScale: Double(resolution.height) / 720))
        let podcast = try SummaryJSON.decoder().decode(DailyPodcast.self, from: Data(#"""
        {"key":"test","title":"Motion","language":"en","createdAt":"2030-03-10T05:00:00Z",
        "durationSeconds":1,"speakers":[{"name":"Alex","voice":"fixture"}],
        "segments":[{"speaker":0,"chipId":"one","caption":"Hello 世界.","icon":"☕️","startSeconds":0,"endSeconds":1,"voiceStartSeconds":0.2,"voiceEndSeconds":0.8,"captionCues":[{"text":"Hello 世界","startSeconds":0.2,"endSeconds":0.8}]}]}
        """#.utf8))
        try PodcastVideoExporter.embedCaptions(in: output, podcast: podcast, width: resolution.width, height: resolution.height)
        #expect(try await PodcastMotionRenderer.reusableVideo(at: output))
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .subtitle).count == 1)
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        #expect(group?.options.contains { $0.mediaType == .subtitle && $0.locale?.language.languageCode?.identifier == "en" } == true)
        let texts = try await subtitleTexts(in: asset)
        #expect(texts.contains("Hello 世界"))
        #expect(texts.first == "" && texts.last == "")
        #expect(PodcastVideoExporter.cues(for: podcast).first?.start == 0.2)
        #expect(PodcastVideoExporter.cues(for: podcast).last?.end == 0.8)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.15)
        let images = AVAssetImageGenerator(asset: asset)
        images.requestedTimeToleranceBefore = .zero
        images.requestedTimeToleranceAfter = .zero
        let first = try await images.image(at: CMTime(seconds: 0.25, preferredTimescale: 12)).image
        let last = try await images.image(at: CMTime(seconds: 0.75, preferredTimescale: 12)).image
        #expect(first.width == resolution.width && first.height == resolution.height)
        #expect(first.dataProvider?.data != last.dataProvider?.data)
    }

    private func subtitleTexts(in asset: AVAsset) async throws -> [String] {
        let subtitle = try #require(try await asset.loadTracks(withMediaType: .subtitle).first)
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: subtitle, outputSettings: nil)
        reader.add(trackOutput)
        #expect(reader.startReading())
        var texts: [String] = []
        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            #expect(status == kCMBlockBufferNoErr)
            if bytes.count >= 2 {
                let count = Int(bytes[0]) * 256 + Int(bytes[1])
                texts.append(String(decoding: bytes.dropFirst(2).prefix(count), as: UTF8.self))
            }
        }
        return texts
    }

    private func wave() -> Data {
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); word(UInt32(16_036)); data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8_000)); word(UInt32(16_000))
        word(UInt16(2)); word(UInt16(16)); data.append(Data("data".utf8)); word(UInt32(16_000))
        data.append(Data(repeating: 0, count: 16_000))
        return data
    }
}

private struct MediaTestToken: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "unused" }
}
