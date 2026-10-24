import AVFoundation
import CoreGraphics
import ImageIO
import SummaryKit
import SwiftUI

/// Renders the persisted episode locally. No model calls, credentials in exports or server video jobs.
@MainActor enum PodcastVideoExporter {
    private static let width = 1280
    private static let height = 720
    private static let fps: Int32 = 15

    static func export(api: SummaryAPIClient, podcast: DailyPodcast, audioURL: URL, directory: URL) async throws -> URL {
        let audioAsset = AVURLAsset(url: audioURL)
        let duration = try await audioAsset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, !podcast.segments.isEmpty else { throw SummaryAPIError.invalidResponse }
        let frames = try await renderFrames(api: api, podcast: podcast)
        let silentURL = directory.appending(path: "covers.mp4")
        try await writeVideo(frames: frames, podcast: podcast, duration: duration, url: silentURL)
        try Task.checkCancellation()
        let videoAsset = AVURLAsset(url: silentURL)
        let composition = AVMutableComposition()
        try await insertTrack(from: videoAsset, type: .video, into: composition, duration: duration)
        try await insertTrack(from: audioAsset, type: .audio, into: composition, duration: duration)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw SummaryAPIError.invalidResponse
        }
        let output = directory.appending(path: "podcast.mp4")
        try await session.export(to: output, as: .mp4)
        try? FileManager.default.removeItem(at: silentURL)
        return output
    }

    private static func insertTrack(from asset: AVAsset, type: AVMediaType, into composition: AVMutableComposition, duration: CMTime) async throws {
        guard let source = try await asset.loadTracks(withMediaType: type).first,
              let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SummaryAPIError.invalidResponse
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
    }

    private static func renderFrames(api: SummaryAPIClient, podcast: DailyPodcast) async throws -> [CGImage] {
        var artwork: [String: CGImage] = [:]
        var attempted: Set<String> = []
        var frames: [CGImage] = []
        for segment in podcast.segments {
            try Task.checkCancellation()
            if let path = segment.imagePath, attempted.insert(path).inserted,
               let data = try? await api.dailyPodcastArtwork(path),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { artwork[path] = image }
            let speaker = podcast.speakers.indices.contains(segment.speaker) ? podcast.speakers[segment.speaker].name : ""
            let view = PodcastVideoFrame(title: podcast.title, caption: segment.caption, speaker: speaker,
                                         icon: segment.icon, image: segment.imagePath.flatMap { artwork[$0] })
                .frame(width: CGFloat(width), height: CGFloat(height))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage else { throw SummaryAPIError.invalidResponse }
            frames.append(image)
        }
        return frames
    }

    private static func writeVideo(frames: [CGImage], podcast: DailyPodcast, duration: CMTime, url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw SummaryAPIError.invalidResponse }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SummaryAPIError.invalidResponse }
        writer.startSession(atSourceTime: .zero)
        do {
            try await appendFrames(frames, podcast: podcast, duration: duration, input: input, adaptor: adaptor, writer: writer)
            writer.endSession(atSourceTime: duration)
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? SummaryAPIError.invalidResponse }
        } catch { writer.cancelWriting(); throw error }
    }

    private static func appendFrames(_ frames: [CGImage], podcast: DailyPodcast, duration: CMTime,
                                     input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter) async throws {
        var lastIndex = -1
        var buffer: CVPixelBuffer?
        for frame in 0..<Int(ceil(duration.seconds * Double(fps))) {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? SummaryAPIError.invalidResponse }
                try await Task.sleep(for: .milliseconds(2))
            }
            let time = CMTime(value: Int64(frame), timescale: fps)
            let index = min(frames.count - 1, podcast.segmentIndex(at: time.seconds))
            if index != lastIndex { buffer = try pixelBuffer(frames[index]); lastIndex = index }
            guard let buffer, adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? SummaryAPIError.invalidResponse }
            if frame % 15 == 0 { await Task.yield() }
        }
    }

    private static func pixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                                        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw SummaryAPIError.invalidResponse }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            throw SummaryAPIError.invalidResponse
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

private struct PodcastVideoFrame: View {
    let title: String
    let caption: String
    let speaker: String
    let icon: String
    let image: CGImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.indigo.gradient)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: 1280, height: 720).clipped()
            } else { Text(icon).font(.system(size: 180)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 30, weight: .bold))
                Text(speaker).font(.system(size: 20, weight: .medium))
                Text(caption).font(.system(size: 26)).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 24))
            .padding(32)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
