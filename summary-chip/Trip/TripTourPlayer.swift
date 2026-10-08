import AVFoundation
import CryptoKit
import Foundation
import Observation
import SummaryKit

/// Plays a trip tour: fetches the narrated scenes, then for each one lets the camera settle,
/// speaks the narration (downloaded once and kept on disk) and pauses before the next, so the
/// route draws and the photos show at a calm pace.
@MainActor
@Observable
final class TripTourPlayer {
    enum Phase: Equatable {
        case loading
        case playing
        case paused
        case finished
        case failed(String)
    }

    let api: SummaryAPIClient
    let tripID: String
    /// Plays only this day's scenes (its opening, rides, sights and night), not the whole trip.
    let dayID: String?
    private(set) var tour: TripTour?
    private(set) var phase: Phase = .loading
    /// The scene on screen.
    private(set) var index = 0
    /// How far through the scene's narration, 0…1.
    private(set) var sceneProgress: Double = 0
    /// Waiting for the scene's narration to download.
    private(set) var isBuffering = false
    /// Bumped when a scene starts, for haptics.
    private(set) var sceneChanges = 0

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var downloads: [Int: Task<Data?, Never>] = [:]

    /// Time for the camera to fly to a scene before the narrator speaks.
    private static let settle: Duration = .milliseconds(1_800)
    /// Quiet between scenes.
    private static let breath: Duration = .milliseconds(1_200)
    /// Reading pace when a scene has no audio.
    private static let secondsPerCharacter = 0.07
    nonisolated private static let cacheDirectory = URL.cachesDirectory.appending(path: "trip-tour-audio", directoryHint: .isDirectory)

    init(api: SummaryAPIClient, tripID: String, dayID: String? = nil) {
        self.api = api
        self.tripID = tripID
        self.dayID = dayID
    }

    var scene: TripTourScene? { tour?.scenes[safe: index] }
    var sceneCount: Int { tour?.scenes.count ?? 0 }
    var isPlaying: Bool { phase == .playing }

    /// Overall progress through the tour, 0…1.
    var overallProgress: Double {
        guard sceneCount > 0 else { return 0 }
        return (Double(index) + sceneProgress) / Double(sceneCount)
    }

    // MARK: Loading

    /// Fetches the tour (written by the server on first play, or again when `regenerate`) and starts it.
    func start(regenerate: Bool = false) async {
        stopScene()
        downloads.values.forEach { $0.cancel() }
        downloads = [:]
        phase = .loading
        do {
            var tour = try await api.tripTour(tripId: tripID, regenerate: regenerate)
            guard !Task.isCancelled else { return }
            if let dayID {
                // The trip's tour is written once; a day plays its own part of it.
                tour.scenes = tour.scenes.filter { $0.dayId == dayID }
            }
            self.tour = tour
            index = 0
            sceneProgress = 0
            sceneChanges += 1
            guard !tour.scenes.isEmpty else {
                phase = .finished
                return
            }
            play()
        } catch is CancellationError {
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Controls

    func play() {
        guard tour != nil else { return }
        if phase == .finished {
            index = 0
            sceneProgress = 0
        }
        phase = .playing
        activateAudioSession()
        if let audio, runTask != nil {
            audio.play()
            return
        }
        if runTask == nil { run(from: index) }
    }

    func pause() {
        guard phase == .playing else { return }
        phase = .paused
        audio?.pause()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func next() { jump(to: index + 1) }

    func previous() {
        // Back to the start of the scene unless it has only just begun.
        jump(to: sceneProgress > 0.15 ? index : index - 1)
    }

    func jump(to target: Int) {
        guard let tour, !tour.scenes.isEmpty else { return }
        let target = max(0, min(tour.scenes.count - 1, target))
        stopScene()
        index = target
        sceneProgress = 0
        sceneChanges += 1
        if phase == .finished { phase = .paused }
        if phase == .playing { run(from: target) }
    }

    /// Stops playback and audio for good (the tour was closed).
    func stop() {
        stopScene()
        downloads.values.forEach { $0.cancel() }
        downloads = [:]
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func stopScene() {
        runTask?.cancel()
        runTask = nil
        audio?.stop()
        audio = nil
        isBuffering = false
    }

    // MARK: Playback

    private func run(from start: Int) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self, let tour = self.tour else { return }
            for position in start..<tour.scenes.count {
                guard !Task.isCancelled else { return }
                if position != start {
                    self.index = position
                    self.sceneProgress = 0
                    self.sceneChanges += 1
                }
                self.prefetch(after: position)
                guard await self.wait(Self.settle) else { return }
                guard await self.narrate(position) else { return }
                guard await self.wait(Self.breath) else { return }
            }
            guard !Task.isCancelled else { return }
            self.runTask = nil
            self.phase = .finished
        }
    }

    /// Sleeps for `duration` of playing time; pausing stops the clock. False when cancelled.
    private func wait(_ duration: Duration) async -> Bool {
        var left = duration
        let tick = Duration.milliseconds(50)
        while left > .zero {
            do { try await Task.sleep(for: tick) } catch { return false }
            if phase == .playing { left -= tick }
        }
        return !Task.isCancelled
    }

    /// Speaks scene `position`, moving `sceneProgress` with the audio (or a reading pace when the
    /// narration couldn't be fetched). False when cancelled.
    private func narrate(_ position: Int) async -> Bool {
        guard let scene = tour?.scenes[safe: position] else { return false }
        isBuffering = true
        let data = await download(position)
        isBuffering = false
        guard !Task.isCancelled else { return false }

        if let data, let player = try? AVAudioPlayer(data: data), player.duration > 0 {
            audio = player
            player.prepareToPlay()
            if phase == .playing { player.play() }
            var started = player.isPlaying
            while true {
                do { try await Task.sleep(for: .milliseconds(33)) } catch {
                    player.stop()
                    return false
                }
                if player.isPlaying { started = true }
                if phase == .playing, !player.isPlaying {
                    // Done once it has played and rewound or reached the end; otherwise it was
                    // stopped by the system (a call) or never started, so carry on.
                    if started, player.currentTime <= 0.01 || player.currentTime >= player.duration - 0.05 { break }
                    player.play()
                }
                sceneProgress = min(1, player.currentTime / player.duration)
            }
            sceneProgress = 1
            audio = nil
            return !Task.isCancelled
        }

        // No narration: read the subtitles at a calm pace instead.
        let seconds = max(5, Double(scene.narration.count) * Self.secondsPerCharacter)
        var elapsed = 0.0
        while elapsed < seconds {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            if phase == .playing { elapsed += 0.05 }
            sceneProgress = min(1, elapsed / seconds)
        }
        return !Task.isCancelled
    }

    // MARK: Audio

    /// Downloads the next scenes' narration while this one plays.
    private func prefetch(after position: Int) {
        for next in position...(position + 2) where next < sceneCount {
            _ = downloadTask(next)
        }
    }

    private func download(_ position: Int) async -> Data? {
        await downloadTask(position).value
    }

    private func downloadTask(_ position: Int) -> Task<Data?, Never> {
        if let task = downloads[position] { return task }
        guard let scene = tour?.scenes[safe: position] else { return Task { nil } }
        let api = api
        let file = Self.cacheFile(for: scene)
        let task = Task.detached(priority: .userInitiated) { () -> Data? in
            if let cached = try? Data(contentsOf: file) { return cached }
            guard let data = try? await api.tripTourAudio(scene) else { return nil }
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }
        downloads[position] = task
        // A failed download is tried again when the scene comes round next.
        Task { [weak self] in
            if await task.value == nil { self?.downloads[position] = nil }
        }
        return task
    }

    /// Named by the scene's audio path and its narration, so a regenerated tour (same path,
    /// new words) never plays the old recording.
    nonisolated private static func cacheFile(for scene: TripTourScene) -> URL {
        let name = scene.audioPath.split(separator: "/").suffix(5).joined(separator: "-")
        let digest = SHA256.hash(data: Data(scene.narration.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appending(path: "\(name)-\(digest).mp3")
    }

    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        #endif
    }
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
