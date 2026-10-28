import AVKit
import SummaryKit
import SwiftUI

struct DailyPodcastPlaybackView: View {
    let api: SummaryAPIClient
    let podcast: DailyPodcast
    @Bindable var player: DailyPodcastPlayer
    let onOpenChip: (String) -> Void
    @State private var taps = 0

    var body: some View {
        GeometryReader { safeArea in
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black
                if podcast.video != nil {
                    #if os(iOS)
                    PodcastNativeVideoPlayer(player: player.videoPlayer)
                        .accessibilityIdentifier("podcast-video-player")
                    #else
                    VideoPlayer(player: player.videoPlayer)
                        .accessibilityIdentifier("podcast-video-player")
                    #endif
                } else {
                if let segment = player.segment {
                    SummaryRemoteImage(url: api.dailyPodcastImageURL(segment.imagePath), authorized: true) {
                        Text(segment.icon).font(.system(size: 120))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.indigo.gradient)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .accessibilityHidden(true)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 12) {
                    Text(podcast.title).font(.headline).lineLimit(2)
                    Text(player.speaker).font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        let lines = player.captionLines
                        ForEach(0..<2, id: \.self) { line in
                            Text(lines.indices.contains(line) ? lines[line] : " ")
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("podcast-caption")
                    #if os(iOS)
                    Button {
                        guard let id = player.segment?.chipId else { return }
                        taps += 1
                        onOpenChip(id)
                    } label: { Label("Open Chip", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("podcast-open-chip")
                    #endif
                    timeline
                    controls
                }
                .padding(20)
                .frame(maxWidth: 680)
                .glassEffect(.regular.tint(.black.opacity(0.25)), in: .rect(cornerRadius: 24))
                .padding(16)
                .padding(.bottom, safeArea.safeAreaInsets.bottom)
                }
            }
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        #if os(iOS)
        .ignoresSafeArea(.container)
        #endif
        }
        .overlay {
            if player.buffering {
                VStack(spacing: 12) {
                    let transfer = podcast.video == nil ? player.transferProgress : player.videoProgress?.transfer
                    if transfer != nil { Text("Downloading podcast…") }
                    else if let progress = player.videoProgress, progress.stage != .preparing { Text(progress.title) }
                    else { Text("Preparing podcast…") }
                    if let fraction = transfer?.fraction ?? player.videoProgress?.fraction {
                        ProgressView(value: fraction).frame(width: 200)
                    } else { ProgressView() }
                    if let transfer { Text(transfer.detail).monospacedDigit() }
                    if let detail = player.videoProgress?.frameDetail { Text("Frames: \(detail)").monospacedDigit() }
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: podcast.video?.id) { player.prepareVideo() }
        .sensoryFeedback(.selection, trigger: taps)
    }

    private var timeline: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                .accessibilityLabel("Podcast playback position")
                .accessibilityIdentifier("podcast-seek")
            HStack {
                Text(Self.timestamp(player.currentTime))
                Spacer()
                Text(Self.timestamp(player.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            Spacer(minLength: 0)
            Button { taps += 1; player.skip(-15) } label: { Label("Back 15 Seconds", systemImage: "gobackward.15") }
            Button { taps += 1; player.toggle() } label: {
                Label(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(minWidth: 44, minHeight: 44)
            }.accessibilityIdentifier("podcast-toggle")
            Button { taps += 1; player.skip(15) } label: { Label("Forward 15 Seconds", systemImage: "goforward.15") }
            Spacer(minLength: 0)
        }
        .font(.title2)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
    }

    private static func timestamp(_ time: Double) -> String {
        let seconds = Int(max(0, time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

#if os(iOS)
/// AVKit supplies native playback controls, including fullscreen and picture in picture.
struct PodcastNativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#endif
