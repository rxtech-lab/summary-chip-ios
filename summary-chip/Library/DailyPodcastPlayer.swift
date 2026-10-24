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

    private var usesPreviewPlayback: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--preview-podcast-playback")
            && ProcessInfo.processInfo.arguments.contains("--preview-likes")
        #else
        false
        #endif
    }

    init(api: SummaryAPIClient) { self.api = api }
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
    func present(date: Date) {
        if self.date != date {
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
    }
    func toggle() {
        if playing { playing = false; audio?.pause(); videoPlayer?.pause(); return }
        if usesPreviewPlayback {
            if currentTime >= duration { seek(to: 0) }
            playing = true
            if task == nil { startPreviewPlayback() }
            return
        }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if currentTime >= duration { seek(to: 0) }
            playing = true
            if let audio { audio.play() }
            videoPlayer?.play()
            if task == nil { loadAndPlay() }
        } catch { self.error = error.localizedDescription }
    }
    /// Loads a video episode into the player without starting it, so its native controls can play it.
    func prepareVideo() {
        guard podcast?.video != nil, videoPlayer == nil, task == nil, !usesPreviewPlayback else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        #endif
        loadAndPlay()
    }
    func seek(to time: Double) {
        currentTime = max(0, min(duration, time))
        audio?.currentTime = currentTime
        videoPlayer?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
    }
    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }
    func stop() {
        task?.cancel()
        task = nil
        audio?.stop()
        audio = nil
        videoPlayer?.pause()
        videoPlayer = nil
        videoProgress = nil
        playing = false
        buffering = false
        #if os(iOS)
        if !usesPreviewPlayback {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
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
            if let length = movie.currentItem?.duration.seconds, length.isFinite, length != duration { duration = length }
            if playing != (movie.rate > 0) { playing = movie.rate > 0 }
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
                    let data = try await api.dailyPodcastAudio(podcast)
                    try Task.checkCancellation()
                    let player = try AVAudioPlayer(data: data)
                    guard player.duration > 0 else { throw SummaryAPIError.invalidResponse }
                    audio = player
                    duration = player.duration
                    player.currentTime = currentTime
                    player.prepareToPlay()
                    buffering = false
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
                }
                currentTime = duration
                playing = false
                task = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                stop()
            }
        }
    }
}
