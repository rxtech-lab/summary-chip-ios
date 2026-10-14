// Re-encodes a screen recording as an H.264 MP4 that fits in a byte budget: the bitrate comes from
// the video's length, and the size steps down when that bitrate is low so the text stays legible.
// Exits 1 when the result is still over the budget, so the caller can try a smaller one.
//
//   swift compress-video.swift <recording.mov> <output.mp4> <max-bytes>
import AVFoundation

let arguments = CommandLine.arguments
guard arguments.count == 4, let maxBytes = Double(arguments[3]) else {
    print("usage: compress-video.swift <input> <output.mp4> <max-bytes>")
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])

let asset = AVURLAsset(url: input)
let duration = try await asset.load(.duration).seconds
guard let track = try await asset.loadTracks(withMediaType: .video).first else {
    print("No video track in \(input.path)")
    exit(2)
}
let natural = try await track.load(.naturalSize)

// Leave room for the container and for the encoder overshooting its average.
let bitrate = max(200_000, maxBytes * 8 * 0.85 / max(duration, 1))
let longSide: Double = bitrate > 2_000_000 ? 1280 : bitrate > 900_000 ? 960 : 720
let scale = min(1, longSide / max(natural.width, natural.height))
let width = Int((natural.width * scale / 2).rounded()) * 2
let height = Int((natural.height * scale / 2).rounded()) * 2
print(String(format: "%.0f s at %.0f kbit/s, %d×%d", duration, bitrate / 1000, width, height))

let reader = try AVAssetReader(asset: asset)
let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
])
reader.add(readerOutput)

try? FileManager.default.removeItem(at: output)
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true
let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: Int(bitrate),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalDurationKey: 4,
    ],
])
writerInput.expectsMediaDataInRealTime = false
writer.add(writerInput)

guard reader.startReading(), writer.startWriting() else {
    print("Could not start: \(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "unknown error")")
    exit(2)
}
var started = false
while let sample = readerOutput.copyNextSampleBuffer() {
    if !started {
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
        started = true
    }
    while !writerInput.isReadyForMoreMediaData { usleep(1_000) }
    guard writerInput.append(sample) else { break }
}
writerInput.markAsFinished()
await writer.finishWriting()

guard reader.status == .completed, writer.status == .completed else {
    print("Failed: \(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "unknown error")")
    exit(2)
}
let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.doubleValue ?? 0
print(String(format: "Wrote %.1f MB", size / 1_048_576))
exit(size <= maxBytes ? 0 : 1)
