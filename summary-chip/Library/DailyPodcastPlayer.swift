import AVFoundation
import Observation
import SummaryKit

@MainActor @Observable
final class DailyPodcastPlayer {
    let api: SummaryAPIClient
    var podcast: DailyPodcast?
    var date: Date?
    var isPresented = false
    var playing = false
    var buffering = false
    var currentTime = 0.0
    var duration = 0.0
    var error: String?
    @ObservationIgnored private var captionTimelines: [Int: PodcastCaptionTimeline] = [:]
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(api: SummaryAPIClient) { self.api = api }
    var index: Int { podcast?.segmentIndex(at: currentTime) ?? 0 }
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }
    var segment: DailyPodcast.Segment? {
        guard let podcast, podcast.segments.indices.contains(index) else { return nil }
        return podcast.segments[index]
    }
    var captionLines: [String] {
        guard let segment else { return [] }
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
    func close() {
        stop()
        podcast = nil
        date = nil
        currentTime = 0
        duration = 0
        error = nil
        isPresented = false
    }

    func replace(_ podcast: DailyPodcast) {
        stop()
        self.podcast = podcast
        captionTimelines = [:]
        currentTime = 0
        duration = podcast.durationSeconds ?? 0
    }
    func toggle() {
        if playing { playing = false; audio?.pause(); return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if currentTime >= duration { seek(to: 0) }
            playing = true
            if let audio { audio.play() }
            if task == nil { loadAndPlay() }
        } catch { self.error = error.localizedDescription }
    }
    func seek(to time: Double) {
        currentTime = max(0, min(duration, time))
        audio?.currentTime = currentTime
    }
    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }
    func stop() {
        task?.cancel()
        task = nil
        audio?.stop()
        audio = nil
        playing = false
        buffering = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    private func loadAndPlay() {
        task = Task { [weak self] in
            guard let self, let podcast else { return }
            do {
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
