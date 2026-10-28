import MediaPlayer
import SummaryKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Publishes the playing episode to the lock screen, Control Center and media keys:
/// the episode title, the current turn's caption as the subtitle, and its artwork.
@MainActor
final class PodcastNowPlaying {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var skip: (Double) -> Void
        var seek: (Double) -> Void
    }

    private let api: SummaryAPIClient
    private var artwork: [String: MPMediaItemArtwork] = [:]
    private var loadingArtwork: Set<String> = []
    private var lastState: (key: String, index: Int)?
    private var artworkPath: String?
    private var registered = false

    init(api: SummaryAPIClient) { self.api = api }

    func register(_ handlers: Handlers) {
        guard !registered else { return }
        registered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in handlers.play(); return .success }
        center.pauseCommand.addTarget { _ in handlers.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in handlers.toggle(); return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { _ in handlers.skip(15); return .success }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in handlers.skip(-15); return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handlers.seek(event.positionTime)
            return .success
        }
    }

    /// Whether the visible turn changed since the last update, so callers refresh only on turn boundaries.
    func needsUpdate(key: String, index: Int) -> Bool {
        guard let lastState else { return true }
        return lastState.key != key || lastState.index != index
    }

    func update(podcast: DailyPodcast, segment: DailyPodcast.Segment?, index: Int, speaker: String,
                currentTime: Double, duration: Double, playing: Bool) {
        lastState = (podcast.key, index)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: podcast.title,
            MPMediaItemPropertyArtist: subtitle(segment: segment, speaker: speaker, podcast: podcast),
            MPMediaItemPropertyAlbumTitle: "Chippy",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        artworkPath = artworkPath(podcast: podcast, segment: segment)
        if let path = artworkPath {
            if let image = artwork[path] {
                info[MPMediaItemPropertyArtwork] = image
            } else {
                // Keep the previous turn's artwork on screen until this one arrives.
                if let previous = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
                    info[MPMediaItemPropertyArtwork] = previous
                }
                loadArtwork(path)
            }
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = playing ? .playing : .paused
        #endif
    }

    func clear() {
        lastState = nil
        artworkPath = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #endif
    }

    private func subtitle(segment: DailyPodcast.Segment?, speaker: String, podcast: DailyPodcast) -> String {
        if let caption = segment?.caption.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            return speaker.isEmpty ? caption : "\(speaker): \(caption)"
        }
        return podcast.speakers.map(\.name).formatted(.list(type: .and))
    }

    /// The current turn's illustration, falling back to the episode's first one as its cover.
    private func artworkPath(podcast: DailyPodcast, segment: DailyPodcast.Segment?) -> String? {
        segment?.imagePath ?? podcast.segments.lazy.compactMap(\.imagePath).first
    }

    private func loadArtwork(_ path: String) {
        guard loadingArtwork.insert(path).inserted else { return }
        Task { [weak self, api] in
            let data = try? await api.dailyPodcastArtwork(path)
            guard let self else { return }
            loadingArtwork.remove(path)
            guard let data, let item = Self.artwork(data) else { return }
            artwork[path] = item
            // Attach it if the turn using this artwork is still on screen.
            let center = MPNowPlayingInfoCenter.default()
            guard artworkPath == path, var info = center.nowPlayingInfo else { return }
            info[MPMediaItemPropertyArtwork] = item
            center.nowPlayingInfo = info
        }
    }

    private nonisolated static func artwork(_ data: Data) -> MPMediaItemArtwork? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        #else
        guard let image = NSImage(data: data) else { return nil }
        #endif
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
