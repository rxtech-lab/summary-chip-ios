import AVFoundation
import Foundation
import SummaryKit
import Testing
@testable import summary_chip

@MainActor @Suite struct PodcastMediaTests {
    @Test func exportsOneVideoWithContinuousAudioAndTimedCovers() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "podcast-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.wav")
        try wave().write(to: source)
        let podcast = try SummaryJSON.decoder().decode(DailyPodcast.self, from: Data(#"""
        {"key":"test","title":"Daily discoveries","language":"en","createdAt":"2030-03-10T05:00:00Z",
        "durationSeconds":1,"speakers":[{"name":"Alex","voice":"fixture"}],
        "segments":[{"speaker":0,"chipId":"one","caption":"Our first story.","icon":"☕️","startSeconds":0,"endSeconds":0.5},
        {"speaker":0,"chipId":"two","caption":"Our next discovery.","icon":"🌊","startSeconds":0.5,"endSeconds":1}]}
        """#.utf8))
        let api = SummaryAPIClient(baseURL: URL(string: "https://unused.test")!, tokenProvider: MediaTestToken())
        let output = try await PodcastVideoExporter.export(api: api, podcast: podcast, audioURL: source, directory: folder)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 15)).image
        let next = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 15)).image
        #expect(first.width == 1280 && first.height == 720)
        #expect(first.dataProvider?.data != next.dataProvider?.data)
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
