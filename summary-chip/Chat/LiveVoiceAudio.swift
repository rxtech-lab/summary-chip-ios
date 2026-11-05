import AVFoundation
import os
import OSLog

/// Capture-time fallback when speaker echo survives voice processing.
private final class VoicePlaybackGate: Sendable {
    private let resumeAt = OSAllocatedUnfairLock(initialState: TimeInterval.zero)
    func begin() { resumeAt.withLock { $0 = .infinity } }
    func end() { resumeAt.withLock { $0 = ProcessInfo.processInfo.systemUptime + 0.5 } }
    var isSuppressed: Bool { resumeAt.withLock { ProcessInfo.processInfo.systemUptime < $0 } }
}

/// Audio graph stays on the main actor; conversion runs only on the input tap's serial callback.
@MainActor
final class LiveVoiceAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let toolPlayer = AVAudioPlayerNode()
    private let toolPlaybackGate = VoicePlaybackGate()
    private var toolCueTask: Task<Void, Never>?
    private let captureMixer = AVAudioMixerNode()
    private let playbackGate = VoicePlaybackGate()
    private var tapped = false
    private var playbackTapped = false
    private var meterTask: Task<Void, Never>?
    private let playbackLevel = OSAllocatedUnfairLock(initialState: 0.0)
    private var queuedFrames: AVAudioFrameCount = 0
    /// Audio given to `play` that hasn't been heard yet.
    var queuedSeconds: TimeInterval { Double(queuedFrames) / 24000 }
    private var playbackGeneration = UUID()
    private var configurationObserver: NSObjectProtocol?
    var onFailure: (() -> Void)?
    var onLevel: ((Double) -> Void)?
    var onPlaybackChanged: ((Bool) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws -> AsyncStream<Data> {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        #if os(iOS) || os(visionOS)
        // Share voice processing (noise suppression, echo cancellation and AGC) on iOS and visionOS.
        // Desktop aggregate initialization can stall, so macOS uses the playback gate.
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingInputMuted = false
        input.isVoiceProcessingAGCEnabled = true
        input.isVoiceProcessingBypassed = false
        #endif
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        engine.attach(player)
        engine.attach(toolPlayer)
        #if os(iOS) || os(visionOS)
        engine.attach(captureMixer)
        #endif
        let mixer = engine.mainMixerNode
        // Keep capture in the rendered graph, without monitoring the microphone
        // through the speaker. The tap remains upstream of this muted mixer.
        #if os(iOS) || os(visionOS)
        engine.connect(input, to: captureMixer, format: source)
        captureMixer.outputVolume = 0
        engine.connect(captureMixer, to: mixer, format: source)
        #endif
        engine.connect(player, to: mixer, format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        engine.connect(toolPlayer, to: mixer, format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        // VoiceProcessingIO requires matching client-side capture/playback formats.
        // Without an explicit output connection, the mixer's first input (Gemini's
        // 24 kHz player) can determine its output rate, mismatching the microphone.
        // Keep the I/O graph at the capture format; the mixer resamples model audio.
        #if os(iOS) || os(visionOS)
        engine.connect(mixer, to: engine.outputNode, format: source)
        #else
        engine.connect(mixer, to: engine.outputNode, format: nil)
        #endif
        // Meter rendered player audio, not network arrival or microphone input.
        let playbackLevel = playbackLevel
        player.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var energy = 0.0
            for index in 0..<Int(buffer.frameLength) {
                let sample = Double(samples[index])
                energy += sample * sample
            }
            let rms = sqrt(energy / Double(buffer.frameLength))
            playbackLevel.withLock { $0 = min(1, rms * 5) }
        }
        playbackTapped = true
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = self.queuedFrames > 0 ? playbackLevel.withLock { $0 } : 0
                self.onLevel?(level)
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let playbackGate = playbackGate
        let toolPlaybackGate = toolPlaybackGate
        // AVFoundation invokes this on its audio thread. Explicit Sendable prevents
        // inheriting MainActor isolation (and trapping before the callback body).
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { @Sendable buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / source.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let samples = converted.int16ChannelData?[0], converted.frameLength > 0 else { return }
            let byteCount = Int(converted.frameLength) * 2
            #if os(macOS) || os(visionOS)
            // Keep provider VAD timing while blocking speaker echo, including the
            // gate's cooldown after playback. visionOS AEC alone can leak speech.
            if playbackGate.isSuppressed || toolPlaybackGate.isSuppressed { continuation.yield(Data(count: byteCount)); return }
            #endif
            continuation.yield(Data(bytes: samples, count: byteCount))
        }
        tapped = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            let underlying = error as NSError
            throw NSError(domain: "Voice", code: underlying.code, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't start the microphone and speaker. Check your sound input and output devices, then try again. (Audio error \(underlying.code))",
                NSUnderlyingErrorKey: underlying,
            ])
        }
        Logger(subsystem: "com.rxlab.summary-chip", category: "VoiceChat").info("Audio engine started; capture rate=\(source.sampleRate), channels=\(source.channelCount)")
        player.play()
        observeConfigurationChanges()
        return stream
    }

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                // Startup can queue configuration notifications before observation begins.
                // Only a change that actually stopped the graph requires reconnecting.
                guard let self, !self.engine.isRunning else { return }
                self.onFailure?()
            }
        }
    }

    func play(_ data: Data) throws {
        guard data.count % 2 == 0, !data.isEmpty else { return }
        let count = data.count / 2
        guard queuedFrames + AVAudioFrameCount(count) <= 24000 * 30 else {
            throw NSError(domain: "Voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio playback fell behind. Please start a new voice session."])
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            let sample = Int16(bitPattern: UInt16(data[index * 2]) | UInt16(data[index * 2 + 1]) << 8)
            channel[index] = Float(sample) / 32768
        }
        // Tool feedback never competes with the spoken announcement or answer.
        toolPlayer.stop()
        toolPlaybackGate.end()
        if queuedFrames == 0 { onPlaybackChanged?(true) }
        playbackGate.begin()
        queuedFrames += buffer.frameLength
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedFrames -= AVAudioFrameCount(count)
                if self.queuedFrames == 0 {
                    self.playbackGate.end()
                    self.onLevel?(0)
                    self.onPlaybackChanged?(false)
                }
            }
        }
    }

    /// Let already queued spoken narration finish before starting the action.
    func waitForSpeechPlayback() async throws {
        while queuedFrames > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
    }

    func setToolActivity(_ active: Bool) {
        guard active else {
            toolCueTask?.cancel(); toolCueTask = nil
            toolPlayer.stop(); toolPlaybackGate.end()
            return
        }
        guard toolCueTask == nil, engine.isRunning else { return }
        toolCueTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.queuedFrames == 0 {
                    self.playToolCue()
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                    self.toolPlaybackGate.end()
                    do { try await Task.sleep(for: .milliseconds(1620)) } catch { return }
                } else {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }
    }

    private func playToolCue() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4320),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = 4320
        // Two soft notes with smooth envelopes, synthesized locally without assets.
        for index in 0..<4320 {
            let noteTime = Double(index % 2160) / 24000
            let frequency = index < 2160 ? 660.0 : 880.0
            let envelope = pow(sin(.pi * noteTime / 0.09), 2)
            samples[index] = Float(0.035 * envelope * sin(2 * .pi * frequency * noteTime))
        }
        toolPlaybackGate.begin()
        toolPlayer.scheduleBuffer(buffer)
        toolPlayer.play()
    }

    func interrupt() {
        setToolActivity(false)
        playbackGeneration = UUID()
        queuedFrames = 0
        playbackLevel.withLock { $0 = 0 }
        onPlaybackChanged?(false)
        playbackGate.end()
        player.stop()
        player.play()
        onLevel?(0)
    }

    func stop() {
        setToolActivity(false)
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        onFailure = nil
        meterTask?.cancel(); meterTask = nil
        if playbackTapped { player.removeTap(onBus: 0); playbackTapped = false }
        onLevel?(0)
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        playbackGeneration = UUID()
        queuedFrames = 0
        playbackLevel.withLock { $0 = 0 }
        onPlaybackChanged?(false)
        playbackGate.end()
        player.stop()
        engine.stop()
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
