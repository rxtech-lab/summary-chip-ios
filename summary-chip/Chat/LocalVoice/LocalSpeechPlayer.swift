#if os(macOS)
import Foundation
import LocalAgentKit

/// Speaks sentences through the Kokoro worker, one at a time and in order.
@MainActor
final class LocalSpeechPlayer {
    /// The audio queue rejects more than 30 seconds, and synthesis is far faster than
    /// speech, so a long reply has to wait for playback to catch up.
    private static let maximumQueuedAudio: TimeInterval = 15

    private let id = UUID().uuidString
    private let language: LocalVoiceLanguage
    private let modelID: String?
    private let runner: LocalAgentRunnerClient
    private var ready: CheckedContinuation<Void, Error>?
    private var isRunning = false
    private var pending: [String] = []
    private var inFlight: String?
    private var pumpRetry: Task<Void, Never>?

    /// Set before `start`, and kept for the whole session.
    var voice: String?
    var seed = LocalVoiceSeed.standard
    var onAudio: ((Data) -> Void)?
    var queuedAudio: (() -> TimeInterval)?
    var onFailure: ((String) -> Void)?
    /// Everything enqueued has been synthesized.
    var onFinished: (() -> Void)?
    /// One sentence couldn't be read. A conversation carries on without it, so this is optional.
    var onSpeechError: ((String) -> Void)?

    /// Whether anything is still waiting to be synthesized.
    var isBusy: Bool { inFlight != nil || !pending.isEmpty }

    /// Without a `modelID`, it speaks with the model selected for voice chat.
    init(language: LocalVoiceLanguage, modelID: String? = nil, runner: LocalAgentRunnerClient = .shared) {
        self.language = language
        self.modelID = modelID
        self.runner = runner
    }

    /// Returns once the model has loaded.
    func start() async throws {
        let handler = LocalAgentRunnerClient.ProcessHandler(
            onLine: { [weak self] in self?.receive($0) },
            onExit: { [weak self] _, message in self?.workerExited(message) }
        )
        try await runner.startSpeechWorker(id: id, modelID: modelID, seed: seed, handler: handler)
        isRunning = true
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { ready = $0 }
    }

    func enqueue(_ sentence: String) {
        pending.append(sentence)
        pump()
    }

    /// Stops the current reply. The worker drops what's queued, and any late audio is ignored.
    func cancelAll() {
        pending = []
        inFlight = nil
        pumpRetry?.cancel()
        pumpRetry = nil
        if isRunning { runner.write(id: id, data: SpeechWorkerEvent.cancelLine) }
    }

    func stop() {
        cancelAll()
        isRunning = false
        finishWaiting(throwing: CancellationError())
        runner.terminate(id: id)
    }

    private func pump() {
        guard inFlight == nil, isRunning, !pending.isEmpty else { return }
        guard (queuedAudio?() ?? 0) < Self.maximumQueuedAudio else {
            guard pumpRetry == nil else { return }
            pumpRetry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.pumpRetry = nil
                self?.pump()
            }
            return
        }
        let identifier = UUID().uuidString
        inFlight = identifier
        runner.write(id: id, data: SpeechWorkerEvent.speakLine(id: identifier, text: pending.removeFirst(), language: language, voice: voice, seed: seed))
    }

    private func receive(_ line: Data) {
        switch SpeechWorkerEvent(line: line) {
        case .ready:
            finishWaiting(throwing: nil)
            pump()
        case .audio(let identifier, let pcm):
            if identifier == inFlight { onAudio?(pcm) }
        case .done(let identifier):
            sentenceEnded(identifier)
        case .error(let identifier, let message):
            // One sentence the model can't read shouldn't end the conversation.
            if let identifier, identifier == inFlight { onSpeechError?(message) }
            if let identifier { sentenceEnded(identifier) }
        case .fatal(let message):
            finishWaiting(throwing: LocalVoiceFailure(message))
            onFailure?(message)
        case nil:
            break
        }
    }

    private func sentenceEnded(_ identifier: String) {
        guard identifier == inFlight else { return }
        inFlight = nil
        pump()
        if !isBusy { onFinished?() }
    }

    private func workerExited(_ message: String?) {
        isRunning = false
        let description = String(localized: "The on-device voice stopped unexpectedly.")
        finishWaiting(throwing: LocalVoiceFailure(description))
        onFailure?(description)
        if let message { runnerLogger.error("Speech worker exited: \(message, privacy: .public)") }
    }

    private func finishWaiting(throwing error: Error?) {
        guard let ready else { return }
        self.ready = nil
        if let error { ready.resume(throwing: error) } else { ready.resume() }
    }
}
#endif
