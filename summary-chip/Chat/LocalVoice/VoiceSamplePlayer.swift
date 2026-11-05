#if os(macOS)
import AVFoundation
import Foundation
import LocalAgentKit
import Observation

/// Plays one sample sentence from a voice model. The model stays loaded between samples,
/// so trying another seed only takes as long as making its voice.
@MainActor @Observable
final class VoiceSamplePlayer {
    enum Phase { case idle, preparing, playing }

    private(set) var phase = Phase.idle
    var errorMessage: String?

    @ObservationIgnored private var speech: LocalSpeechPlayer?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// Made on first use, because SwiftUI creates one of these players on every parent update and keeps only the first.
    @ObservationIgnored private var output: (engine: AVAudioEngine, node: AVAudioPlayerNode, format: AVAudioFormat)?
    /// Buffers of a stopped sample still report back, and mustn't count towards the next one.
    @ObservationIgnored private var playback = 0
    @ObservationIgnored private var buffersPlaying = 0
    @ObservationIgnored private var isSynthesisDone = false

    func play(modelID: String, seed: Int, voice: String?) {
        guard phase == .idle else { return }
        phase = .preparing
        playback += 1
        buffersPlaying = 0
        isSynthesisDone = false
        let current = playback
        let language = LocalVoiceLanguage.resolve(saved: UserDefaults.standard.string(forKey: LiveVoiceSettings.languageKey))
        starting = Task {
            do {
                let speech = try await loadedSpeech(modelID: modelID, seed: seed, language: language)
                // Stopped while the model was loading, which it was worth letting finish.
                guard current == playback else { return }
                speech.seed = seed
                speech.voice = voice
                speech.enqueue(language.sampleText)
            } catch is CancellationError {
                return
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Stops the sound and keeps the model loaded for the next sample.
    func stop() {
        playback += 1
        speech?.cancelAll()
        output?.node.stop()
        phase = .idle
    }

    /// Releases the model. Voice chat and model changes need the runner to be free of it.
    func shutdown() {
        stop()
        starting?.cancel()
        speech?.stop()
        speech = nil
        output?.engine.stop()
    }

    private func loadedSpeech(modelID: String, seed: Int, language: LocalVoiceLanguage) async throws -> LocalSpeechPlayer {
        if let speech { return speech }
        let speech = LocalSpeechPlayer(language: language, modelID: modelID)
        speech.seed = seed
        speech.onAudio = { [weak self] in self?.schedule($0) }
        speech.onFinished = { [weak self] in
            self?.isSynthesisDone = true
            self?.finishIfDone()
        }
        speech.onSpeechError = { [weak self] in self?.fail($0) }
        speech.onFailure = { [weak self] in self?.fail($0) }
        self.speech = speech
        do {
            try await speech.start()
        } catch {
            speech.stop()
            if self.speech === speech { self.speech = nil }
            throw error
        }
        return speech
    }

    private func schedule(_ pcm: Data) {
        let count = pcm.count / 2
        guard phase != .idle, count > 0, let output = audioOutput(),
              let buffer = AVAudioPCMBuffer(pcmFormat: output.format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { bytes in
            for index in 0..<count {
                channel[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
        do {
            if !output.engine.isRunning { try output.engine.start() }
        } catch {
            fail(error.localizedDescription)
            return
        }
        buffersPlaying += 1
        let current = playback
        output.node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(current) }
        }
        if !output.node.isPlaying { output.node.play() }
        phase = .playing
    }

    private func audioOutput() -> (engine: AVAudioEngine, node: AVAudioPlayerNode, format: AVAudioFormat)? {
        if let output { return output }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else { return nil }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        output = (engine, node, format)
        return output
    }

    private func bufferPlayed(_ finished: Int) {
        guard finished == playback else { return }
        buffersPlaying -= 1
        finishIfDone()
    }

    private func finishIfDone() {
        guard phase != .idle, isSynthesisDone, buffersPlaying == 0 else { return }
        stop()
    }

    private func fail(_ message: String) {
        // Even after Stop: a worker that has died can't play the next sample.
        if phase != .idle { errorMessage = message }
        shutdown()
    }
}
#endif
