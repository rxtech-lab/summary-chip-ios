#if os(macOS)
import AVFoundation
import Speech

/// Transcribes live microphone audio on device with Apple's speech model. Each utterance gets its
/// own analyzer: starting one is instant, and finishing one reliably returns everything said,
/// where a shared one holds results back in some languages and blurs where utterances meet.
@MainActor
final class LocalSpeechRecognizer {
    private struct Run {
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        let text: Task<String, Error>
    }

    private static let inputSampleRate = 16000.0
    private var locale: Locale?
    private var run: Run?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Downloads Apple's model for this language if needed, then starts listening.
    func start(localeIdentifier: String) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw LocalVoiceFailure(String(localized: "On-device speech recognition isn't available on this Mac."))
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw LocalVoiceFailure(String(localized: "On-device speech recognition doesn't support this language."))
        }
        let transcriber = Self.transcriber(locale)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LocalVoiceFailure(String(localized: "On-device speech recognition couldn't use the microphone's audio."))
        }
        self.format = format
        self.locale = locale
        run = try await makeRun(locale: locale)
    }

    /// 16 kHz mono 16-bit samples, as `LiveVoiceAudio` captures them.
    func append(_ pcm: Data) {
        guard let run, let format, !pcm.isEmpty, let buffer = Self.buffer(pcm), let converted = convert(buffer, to: format) else { return }
        run.input.yield(AnalyzerInput(buffer: converted))
    }

    /// Returns what was said since the last call. Audio arriving meanwhile counts toward the next utterance.
    func finishUtterance() async throws -> String {
        guard let locale, let finished = run else { return "" }
        run = try await makeRun(locale: locale)
        finished.input.finish()
        try await finished.analyzer.finalizeAndFinishThroughEndOfInput()
        return try await finished.text.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Throws away audio that turned out to hold nothing worth reading.
    func discardAudio() async throws {
        guard let locale, let discarded = run else { return }
        run = try await makeRun(locale: locale)
        Self.cancel(discarded)
    }

    func stop() {
        if let run { Self.cancel(run) }
        run = nil
        locale = nil
    }

    private static func cancel(_ run: Run) {
        run.input.finish()
        run.text.cancel()
        Task { await run.analyzer.cancelAndFinishNow() }
    }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    private func makeRun(locale: Locale) async throws -> Run {
        let transcriber = Self.transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (sequence, input) = AsyncStream<AnalyzerInput>.makeStream()
        let text = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        try await analyzer.start(inputSequence: sequence)
        return Run(analyzer: analyzer, input: input, text: text)
    }

    private static func buffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputSampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let channel = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
        pcm.withUnsafeBytes { channel.update(from: $0.bindMemory(to: Int16.self).baseAddress!, count: pcm.count / 2) }
        return buffer
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
#endif
