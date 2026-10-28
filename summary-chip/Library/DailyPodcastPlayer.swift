import AVFoundation
import Observation
import Foundation
import SummaryKit

@MainActor @Observable
final class DailyPodcastPlayer {
    let api: SummaryAPIClient
    var podcast: DailyPodcast?
    var date: Date?
    var isPresented = false
    var inlinePodcastKey: String?
    var playing = false
    var buffering = false
    var videoPlayer: AVPlayer?
    var videoProgress: PodcastMotionRenderer.Progress?
    var transferProgress: MediaTransferProgress?
    var currentTime = 0.0
    var duration = 0.0
    var error: String?
    /// The language being loaded while switching; playback resumes at the same turn in it.
    var switchingLanguage: String?
    /// The listener's last chosen podcast language, applied to episodes translated into it.
    var preferredLanguage: String? {
        get { access(keyPath: \.preferredLanguage); return UserDefaults.standard.string(forKey: "podcastPreferredLanguage") }
        set { withMutation(keyPath: \.preferredLanguage) { UserDefaults.standard.set(newValue, forKey: "podcastPreferredLanguage") } }
    }
    @ObservationIgnored private var captionTimelines: [Int: PodcastCaptionTimeline] = [:]
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var task: Task<Void, Never>?
    private(set) var interrupted = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private let nowPlaying: PodcastNowPlaying
    /// Bumped by each play/stop so a slow session activation can't resume after a later stop.
    @ObservationIgnored private var activationGeneration = 0
    #if os(iOS)
    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    #endif

    private var usesPreviewPlayback: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--preview-podcast-playback")
            && ProcessInfo.processInfo.arguments.contains("--preview-likes")
        #else
        false
        #endif
    }

    init(api: SummaryAPIClient) {
        self.api = api
        nowPlaying = PodcastNowPlaying(api: api)
        nowPlaying.register(.init(
            play: { [weak self] in if self?.playing == false { self?.toggle() } },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.toggle() },
            skip: { [weak self] in self?.skip($0) },
            seek: { [weak self] in self?.seek(to: $0) }
        ))
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.beginInterruption()
                case .ended: self?.endInterruption(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                @unknown default: break
                }
            }
        }
        #endif
    }

    deinit {
        #if os(iOS)
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        #endif
    }
    var index: Int { podcast?.segmentIndex(at: currentTime) ?? 0 }
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }
    var segment: DailyPodcast.Segment? {
        guard let podcast, podcast.segments.indices.contains(index) else { return nil }
        return podcast.segments[index]
    }
    var captionLines: [String] {
        guard let segment else { return [] }
        if let cues = segment.captionCues {
            return PodcastCaptionTimeline.lines(at: currentTime, cues: cues)
        }
        if captionTimelines[index] == nil { captionTimelines[index] = PodcastCaptionTimeline(segment.caption) }
        // Time against the audible voice, not the turn's padded length, and snap to its measured pauses.
        let timing = PodcastCaptionTimeline.Timing(start: segment.voiceStartSeconds ?? segment.startSeconds ?? 0,
                                                   end: segment.voiceEndSeconds ?? segment.endSeconds ?? duration,
                                                   pauses: segment.pauseSeconds ?? [])
        return captionTimelines[index]?.lines(at: currentTime, timing: timing) ?? []
    }
    var speaker: String {
        guard let podcast, let segment, podcast.speakers.indices.contains(segment.speaker) else { return "" }
        return podcast.speakers[segment.speaker].name
    }
    func present(date: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
        let formatter = ISO8601DateFormatter()
        // A library episode can have the same day as a recap. Validate the
        // loaded episode's scope and bounds, not the last presentation date.
        let matchesDay = podcast.map {
            $0.resolvedType == .daily
                && $0.day.flatMap { formatter.date(from: $0.start) } == start
                && $0.day.flatMap { formatter.date(from: $0.end) } == end
        } ?? false
        if !matchesDay {
            stop()
            podcast = nil
            currentTime = 0
            duration = 0
            error = nil
        }
        self.date = date
        isPresented = true
    }
    func present(podcast: DailyPodcast) {
        if self.podcast?.key != podcast.key || self.podcast?.video?.id != podcast.video?.id { replace(podcast) }
        date = podcast.day.flatMap { ISO8601DateFormatter().date(from: $0.start) } ?? Date()
        isPresented = true
    }
    func close() {
        stop()
        podcast = nil
        date = nil
        currentTime = 0
        duration = 0
        error = nil
        isPresented = false
    }

    /// Plays the episode in another of its languages from the start of the same turn (turns match one to one).
    func switchLanguage(to language: String, remember: Bool = true) async {
        guard let podcast, podcast.language != language, switchingLanguage == nil else { return }
        if remember { preferredLanguage = language }
        let turn = index
        let wasPlaying = playing
        switchingLanguage = language
        defer { switchingLanguage = nil }
        do {
            let episode = try await api.podcastEpisode(podcast, language: language)
            guard self.podcast?.key == podcast.key else { return }
            show(episode, resumingAt: turn, playing: wasPlaying)
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    /// Shows an updated presentation of the current episode (e.g. a new translation) at the same turn.
    func show(_ episode: DailyPodcast, resumingAt turn: Int? = nil, playing resume: Bool? = nil) {
        let turn = turn ?? index
        let resume = resume ?? playing
        replace(episode)
        if episode.segments.indices.contains(turn) { seek(to: episode.segments[turn].startSeconds ?? 0) }
        if resume { toggle() }
    }

    /// Opens a newly loaded episode in the listener's preferred language when it has one.
    func applyPreferredLanguage() async {
        guard let podcast, let preferred = preferredLanguage, podcast.language != preferred,
              podcast.availableLanguages.contains(preferred) else { return }
        await switchLanguage(to: preferred, remember: false)
    }

    func replace(_ podcast: DailyPodcast) {
        stop()
        self.podcast = podcast
        captionTimelines = [:]
        currentTime = 0
        duration = podcast.durationSeconds ?? 0
        refreshNowPlaying()
    }
    func toggle() {
        if playing { pause(); return }
        // Do not reactivate the session while another app or a call owns it.
        if interrupted { resumeAfterInterruption.toggle(); return }
        if usesPreviewPlayback {
            if currentTime >= duration { seek(to: 0) }
            playing = true
            if task == nil { startPreviewPlayback() }
            return
        }
        if currentTime >= duration { seek(to: 0) }
        playing = true
        refreshNowPlaying()
        #if os(iOS)
        // Activating the session blocks; do it off the main thread, then start playback.
        activationGeneration += 1
        let generation = activationGeneration
        Task { [weak self] in
            do {
                try await Self.setAudioSession(active: true)
            } catch {
                guard let self, generation == activationGeneration else { return }
                self.error = error.localizedDescription
                playing = false
                refreshNowPlaying()
                return
            }
            guard let self, generation == activationGeneration, playing else { return }
            startPlayback()
        }
        #else
        startPlayback()
        #endif
    }

    private func startPlayback() {
        audio?.play()
        videoPlayer?.play()
        if task == nil { loadAndPlay() }
    }

    /// Reopens the current episode at the same position. Failed cloud renders are
    /// claimed again by the render endpoint without regenerating the composition.
    func retryPlayback() {
        guard podcast != nil else { return }
        stop()
        error = nil
        toggle()
    }

    func pause() {
        resumeAfterInterruption = false
        playing = false
        audio?.pause()
        videoPlayer?.pause()
        refreshNowPlaying()
    }

    func beginInterruption() {
        guard !interrupted else { return }
        let shouldResume = playing || audio?.isPlaying == true || (videoPlayer?.rate ?? 0) > 0
        pause()
        interrupted = true
        resumeAfterInterruption = shouldResume
    }

    func endInterruption(shouldResume: Bool) {
        guard interrupted else { return }
        let resume = shouldResume && resumeAfterInterruption
        interrupted = false
        resumeAfterInterruption = false
        if resume { toggle() }
    }
    /// Loads a video episode into the player without starting it, so its native controls can play it.
    func prepareVideo() {
        guard podcast?.video != nil, videoPlayer == nil, task == nil, !usesPreviewPlayback else { return }
        #if os(iOS)
        // Native controls may start it without `toggle()`, so the category must allow background audio.
        Self.audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        }
        #endif
        loadAndPlay()
    }
    func seek(to time: Double) {
        currentTime = max(0, min(duration, time))
        audio?.currentTime = currentTime
        videoPlayer?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
        refreshNowPlaying()
    }
    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }
    func stop() {
        resumeAfterInterruption = false
        task?.cancel()
        task = nil
        audio?.stop()
        audio = nil
        videoPlayer?.pause()
        videoPlayer = nil
        videoProgress = nil
        transferProgress = nil
        playing = false
        buffering = false
        nowPlaying.clear()
        #if os(iOS)
        activationGeneration += 1
        if !usesPreviewPlayback {
            Task { try? await Self.setAudioSession(active: false) }
        }
        #endif
    }

    #if os(iOS)
    /// One serial queue keeps activations and deactivations in the order they were requested.
    private nonisolated static let audioSessionQueue = DispatchQueue(label: "app.rxlab.summary-chip.podcast-audio-session", qos: .userInitiated)

    /// `setActive` can block for a while, so it never runs on the main thread.
    private nonisolated static func setAudioSession(active: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioSessionQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    if active {
                        try session.setCategory(.playback, mode: .spokenAudio)
                        try session.setActive(true)
                    } else {
                        try session.setActive(false, options: .notifyOthersOnDeactivation)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    #endif

    /// Publishes the episode, current turn and position to the lock screen and Control Center.
    private func refreshNowPlaying() {
        guard let podcast, !usesPreviewPlayback else { return }
        nowPlaying.update(podcast: podcast, segment: segment, index: index, speaker: speaker,
                          currentTime: currentTime, duration: duration, playing: playing)
    }

    /// Refreshes Now Playing only when playback crosses into another turn.
    private func refreshNowPlayingIfTurnChanged() {
        guard let podcast, nowPlaying.needsUpdate(key: podcast.key, index: index) else { return }
        refreshNowPlaying()
    }

    /// UI fixtures exercise playback state without the simulator's audio device. In CI,
    /// AVAudioPlayer preparation can deadlock against XCTest's screen-recording audio capture.
    private func startPreviewPlayback() {
        task = Task { [weak self] in
            let clock = ContinuousClock()
            var previous = clock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self else { return }
                let now = clock.now
                let elapsed = previous.duration(to: now).components
                previous = now
                guard playing else { continue }
                currentTime = min(duration, currentTime + Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                if currentTime >= duration {
                    playing = false
                    task = nil
                    return
                }
            }
        }
    }
    private func playVideo(_ podcast: DailyPodcast) async throws {
        buffering = true
        let url = try await PodcastMotionRenderer.render(api: api, podcast: podcast) { [weak self] in self?.videoProgress = $0 }
        try Task.checkCancellation()
        let movie = AVPlayer(url: url)
        movie.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        videoPlayer = movie
        await movie.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
        buffering = false
        videoProgress = nil
        if playing { movie.play() }
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(100))
            if let failure = movie.currentItem?.error { throw failure }
            let time = movie.currentTime().seconds
            if time.isFinite { currentTime = time }
            if let length = movie.currentItem?.duration.seconds, length.isFinite, length != duration { duration = length; refreshNowPlaying() }
            if !interrupted, playing != (movie.rate > 0) { playing = movie.rate > 0; refreshNowPlaying() }
            refreshNowPlayingIfTurnChanged()
        }
    }

    private func loadAndPlay() {
        task = Task { [weak self] in
            guard let self, let podcast else { return }
            do {
                if podcast.video != nil {
                    try await playVideo(podcast)
                    return
                }
                if audio == nil {
                    buffering = true
                    let data = try await api.dailyPodcastAudio(podcast) { [weak self] value in
                        guard self?.buffering == true else { return }
                        self?.transferProgress = value
                    }
                    try Task.checkCancellation()
                    let player = try AVAudioPlayer(data: data)
                    guard player.duration > 0 else { throw SummaryAPIError.invalidResponse }
                    audio = player
                    duration = player.duration
                    player.currentTime = currentTime
                    player.prepareToPlay()
                    buffering = false
                    refreshNowPlaying()
                }
                guard let player = audio else { return }
                var started = false
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(50))
                    if player.isPlaying { started = true }
                    if playing {
                        if started && !player.isPlaying && (player.currentTime == 0 || player.currentTime >= player.duration - 0.05) { break }
                        if !player.isPlaying {
                            guard player.play() else { throw SummaryAPIError.invalidResponse }
                            started = true
                        }
                    }
                    currentTime = player.currentTime
                    refreshNowPlayingIfTurnChanged()
                }
                currentTime = duration
                playing = false
                task = nil
                refreshNowPlaying()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                stop()
            }
        }
    }
}
