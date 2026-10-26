import Foundation
import SummaryKit

/// Adds a selectable tx3g subtitle track without decoding or changing any video/audio samples.
/// Existing chunk offsets stay valid: the old moov becomes free space and the new moov is appended.
/// Subtitle sample format: https://developer.apple.com/documentation/quicktime-file-format/subtitle_sample_data
@MainActor enum PodcastVideoExporter {
    struct Cue { var start: Double; var end: Double; var text: String }

    static func cues(for podcast: DailyPodcast) -> [Cue] {
        podcast.segments.flatMap { segment -> [Cue] in
            if let cues = segment.captionCues {
                return PodcastCaptionTimeline.pagedCues(cues)
                    .map { Cue(start: $0.startSeconds, end: $0.endSeconds, text: $0.text) }
            }
            let start = segment.voiceStartSeconds ?? segment.startSeconds ?? 0
            let end = segment.voiceEndSeconds ?? segment.endSeconds ?? podcast.durationSeconds ?? start
            guard start.isFinite, end.isFinite, end > start else { return [] }
            let timeline = PodcastCaptionTimeline(segment.caption)
            let ends = timeline.phraseEnds(.init(start: start, end: end, pauses: segment.pauseSeconds ?? []))
            return timeline.phrases.indices.map { index in
                Cue(start: index == 0 ? start : ends[index - 1], end: ends[index], text: PodcastCaptionTimeline.withoutPunctuation(timeline.phrases[index]))
            }
        }.sorted { $0.start < $1.start }
    }

    /// Standalone subtitles share the exact cue timeline used by the MP4 subtitle track.
    static func subtitleData(for podcast: DailyPodcast) throws -> Data {
        let captions = cues(for: podcast).filter { !$0.text.isEmpty }
        guard !captions.isEmpty else { throw SummaryAPIError.invalidResponse }
        func timestamp(_ seconds: Double) -> String {
            let milliseconds = Int64((max(0, seconds) * 1000).rounded())
            return String(format: "%02lld:%02lld:%02lld,%03lld", milliseconds / 3_600_000,
                          milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
        }
        let text = captions.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
        return Data(text.utf8)
    }

    static func embedCaptions(in url: URL, podcast: DailyPodcast, width: Int = 1280, height: Int = 720) throws {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        let (movie, movieOffset) = try readMovie(file, length: length)
        guard var movie, let mvhd = try children(movie).first(where: { $0.type == "mvhd" }) else { throw SummaryAPIError.invalidResponse }
        let version = movie[mvhd.start + 8]
        let timeOffset = mvhd.start + (version == 1 ? 28 : 20)
        let timescale = read32(movie, timeOffset)
        guard timescale > 0 else { throw SummaryAPIError.invalidResponse }
        let trackID = read32(movie, mvhd.end - 4)
        guard trackID > 0, trackID < UInt32.max else { throw SummaryAPIError.invalidResponse }
        movie.replaceSubrange((mvhd.end - 4)..<mvhd.end, with: u32(trackID + 1))
        let duration = podcast.durationSeconds ?? podcast.segments.compactMap(\.endSeconds).max() ?? 0
        guard duration.isFinite, duration > 0, duration * 1000 < Double(UInt32.max), duration * Double(timescale) < Double(UInt32.max) else { throw SummaryAPIError.invalidResponse }
        let end = UInt32((duration * 1000).rounded())
        var samples: [(duration: UInt32, bytes: Data)] = []
        var at: UInt32 = 0
        func add(_ text: String, until: UInt32) throws {
            guard until > at else { return }
            let bytes = Data(text.utf8)
            guard bytes.count <= Int(UInt16.max) else { throw SummaryAPIError.invalidResponse }
            samples.append((until - at, u16(UInt16(bytes.count)) + bytes))
            at = until
        }
        for cue in cues(for: podcast) {
            let start = UInt32(min(Double(end), max(0, cue.start * 1000)).rounded())
            let finish = UInt32(min(Double(end), max(0, cue.end * 1000)).rounded())
            try add("", until: start)
            try add(cue.text, until: finish)
        }
        try add("", until: end)
        guard !samples.isEmpty else { return }
        let payload = samples.reduce(into: Data()) { $0.append($1.bytes) }
        let track = subtitleTrack(id: trackID, duration: end, movieDuration: UInt32((duration * Double(timescale)).rounded()),
                                  language: podcast.language, width: width, height: height, samples: samples, chunkOffset: length + 8)
        let newMovie = atom("moov", Data(movie.dropFirst(8)) + track)
        try file.seekToEnd()
        try file.write(contentsOf: atom("mdat", payload))
        try file.write(contentsOf: newMovie)
        try file.seek(toOffset: movieOffset + 4)
        try file.write(contentsOf: Data("free".utf8))
    }

    private static func readMovie(_ file: FileHandle, length: UInt64) throws -> (Data?, UInt64) {
        var offset: UInt64 = 0
        var movie: Data?
        var movieOffset: UInt64 = 0
        while offset + 8 <= length {
            try file.seek(toOffset: offset)
            let header = try file.read(upToCount: 16) ?? Data()
            guard header.count >= 8 else { throw SummaryAPIError.invalidResponse }
            let size32 = read32(header, 0)
            let extended = size32 == 1
            guard !extended || header.count >= 16 else { throw SummaryAPIError.invalidResponse }
            let size = extended ? (UInt64(read32(header, 8)) << 32 | UInt64(read32(header, 12))) : size32 == 0 ? length - offset : UInt64(size32)
            guard size >= (extended ? 16 : 8), size <= length - offset else { throw SummaryAPIError.invalidResponse }
            if String(data: header[4..<8], encoding: .ascii) == "moov" {
                guard !extended, size < 64 * 1024 * 1024 else { throw SummaryAPIError.invalidResponse }
                try file.seek(toOffset: offset)
                movie = try file.read(upToCount: Int(size))
                movieOffset = offset
            }
            // A size-zero mdat would swallow appended atoms; make its original boundary explicit.
            if size32 == 0 {
                guard size <= UInt32.max else { throw SummaryAPIError.invalidResponse }
                try file.seek(toOffset: offset)
                try file.write(contentsOf: u32(UInt32(size)))
            }
            offset += size
        }
        return (movie, movieOffset)
    }

    private static func subtitleTrack(id: UInt32, duration: UInt32, movieDuration: UInt32, language: String, width: Int, height: Int,
                                      samples: [(duration: UInt32, bytes: Data)], chunkOffset: UInt64) -> Data {
        let matrix = [UInt32(0x10000), 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000].reduce(into: Data()) { $0 += u32($1) }
        var header = zeros(8) + u32(id) + zeros(4) + u32(movieDuration) + zeros(8)
        header += u16(0) + u16(2) + zeros(4)
        header += matrix + u32(UInt32(width) << 16) + u32(UInt32(height) << 16)
        let tkhd = full("tkhd", flags: 3, header)
        let codes = ["en": "eng", "zh": "zho", "ja": "jpn", "ko": "kor", "fr": "fra", "de": "deu", "es": "spa", "it": "ita", "pt": "por", "ru": "rus", "ar": "ara"]
        let code = codes[String(language.prefix(2))] ?? "und"
        let packed = code.utf8.reduce(UInt16(0)) { ($0 << 5) | UInt16($1 - 0x60) }
        let mdhd = full("mdhd", zeros(8) + u32(1000) + u32(duration) + u16(packed) + zeros(2))
        let hdlr = full("hdlr", zeros(4) + Data("sbtl".utf8) + zeros(12) + Data("Subtitles\0".utf8))
        let font = atom("ftab", u16(1) + u16(1) + Data([5]) + Data("Arial".utf8))
        let style = zeros(4) + u16(1) + Data([0, UInt8(28 * height / 720), 255, 255, 255, 255])
        var description = zeros(6) + u16(1) + zeros(4) + Data([1, 255]) + zeros(4)
        description += u16(UInt16(600 * height / 720)) + u16(UInt16(40 * width / 1280)) + u16(UInt16(700 * height / 720)) + u16(UInt16(1240 * width / 1280))
        description += style + font
        let entry = atom("tx3g", description)
        let stsd = full("stsd", u32(1) + entry)
        let stts = full("stts", u32(UInt32(samples.count)) + samples.reduce(into: Data()) { $0 += u32(1) + u32($1.duration) })
        let stsc = full("stsc", u32(1) + u32(1) + u32(UInt32(samples.count)) + u32(1))
        let stsz = full("stsz", u32(0) + u32(UInt32(samples.count)) + samples.reduce(into: Data()) { $0 += u32(UInt32($1.bytes.count)) })
        let co64 = full("co64", u32(1) + u32(UInt32(chunkOffset >> 32)) + u32(UInt32(chunkOffset & 0xffffffff)))
        let dinf = atom("dinf", full("dref", u32(1) + full("url ", flags: 1, Data())))
        let minf = atom("minf", full("nmhd", Data()) + dinf + atom("stbl", stsd + stts + stsc + stsz + co64))
        return atom("trak", tkhd + atom("mdia", mdhd + hdlr + minf))
    }

    private struct Box { var type: String; var start: Int; var end: Int }
    private static func children(_ data: Data) throws -> [Box] {
        var result: [Box] = [], offset = 8
        while offset + 8 <= data.count {
            let size = Int(read32(data, offset))
            guard size >= 8, size <= data.count - offset else { throw SummaryAPIError.invalidResponse }
            result.append(Box(type: String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? "", start: offset, end: offset + size))
            offset += size
        }
        return result
    }
    private static func read32(_ data: Data, _ at: Int) -> UInt32 { data[at..<(at + 4)].reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func zeros(_ count: Int) -> Data { Data(repeating: 0, count: count) }
    private static func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func atom(_ type: String, _ data: Data) -> Data { u32(UInt32(data.count + 8)) + Data(type.utf8) + data }
    private static func full(_ type: String, flags: UInt32 = 0, _ data: Data) -> Data { atom(type, u32(flags) + data) }
}
