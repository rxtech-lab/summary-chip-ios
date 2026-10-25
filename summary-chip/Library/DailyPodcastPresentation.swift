import SummaryKit
import SwiftUI

extension EnvironmentValues {
    @Entry var openPodcast: ((Summary) -> Void)?
}

/// The app owns playback; presentation and chip navigation never replace its audio player.
struct DailyPodcastPresentation: ViewModifier {
    let environment: AppEnvironment
    @State private var podcastTask: Task<Void, Never>?
    @State private var openingPodcast = false
    @State private var podcastTaps = 0
    @State private var pendingChipID: String?
    @State private var openingChip = false
    @State private var error: String?
    @State private var openingTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        @Bindable var player = environment.podcastPlayer
        content
            .environment(\.openPodcast, openPodcast)
            .sensoryFeedback(.selection, trigger: podcastTaps)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.showsMiniPlayer, !usesTabAccessory {
                    DailyPodcastMiniPlayer(player: player)
                        .frame(maxWidth: 640)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
            }
            .sheet(isPresented: $player.isPresented, onDismiss: openPendingChip) {
                if let date = player.date {
                    DailyPodcastSheet(api: environment.api, date: date, player: player, onOpenChip: { id in
                        pendingChipID = id
                        player.isPresented = false
                    }, onChipUpdated: { environment.library.upsert($0) })
                }
            }
            .overlay {
                if openingChip || openingPodcast {
                    ProgressView(openingPodcast ? "Loading podcast…" : "Opening chip…")
                        .padding(24)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
            .alert("Couldn't Open Item", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .alert("Couldn't Play Podcast", isPresented: Binding(get: { !player.isPresented && player.error != nil }, set: { if !$0 { player.error = nil } })) {
                Button("OK", role: .cancel) { player.error = nil }
            } message: { Text(player.error ?? "") }
            .onDisappear { openingTask?.cancel(); podcastTask?.cancel() }
    }

    /// `MainTabView` shows the mini player in the tab bar's bottom accessory instead.
    private var usesTabAccessory: Bool {
        #if os(iOS)
        if #available(iOS 27.0, *) { return horizontalSizeClass != .regular }
        #endif
        return false
    }

    private func openPodcast(_ summary: Summary) {
        guard !openingPodcast else { return }
        podcastTaps += 1
        openingPodcast = true
        podcastTask = Task {
            defer { openingPodcast = false }
            do {
                let podcast = try await environment.api.libraryPodcast(summaryID: summary.id)
                try Task.checkCancellation()
                environment.podcastPlayer.present(podcast: podcast)
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func openPendingChip() {
        guard let id = pendingChipID else { return }
        pendingChipID = nil
        openingTask?.cancel()
        openingChip = true
        openingTask = Task {
            defer { openingChip = false }
            do {
                let summary = try await environment.api.summary(id: id)
                try Task.checkCancellation()
                environment.library.upsert(summary)
                environment.pendingLibraryItem = summary
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension DailyPodcastPlayer {
    /// A podcast is loaded but neither its sheet nor an inline player is showing it.
    var showsMiniPlayer: Bool {
        podcast != nil && !isPresented && inlinePodcastKey != podcast?.key
    }
}

#if os(iOS)
extension View {
    /// iOS 27 places the mini player above the tab bar as its bottom accessory.
    @ViewBuilder
    func dailyPodcastTabAccessory(player: DailyPodcastPlayer) -> some View {
        if #available(iOS 27.0, *) {
            tabViewBottomAccessory(isEnabled: player.showsMiniPlayer) {
                DailyPodcastMiniPlayer(player: player, inTabAccessory: true)
            }
        } else {
            self
        }
    }
}
#endif

struct DailyPodcastMiniPlayer: View {
    @Bindable var player: DailyPodcastPlayer
    /// The tab bar accessory supplies its own glass capsule, so the player drops its background.
    var inTabAccessory = false
    @State private var taps = 0
    #if os(iOS)
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
    #endif

    /// The accessory shrinks inline beside the tab bar when it collapses on scroll.
    private var isCompact: Bool {
        #if os(iOS)
        return inTabAccessory && accessoryPlacement == .inline
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { taps += 1; player.isPresented = true } label: {
                HStack(spacing: 12) {
                    SummaryRemoteImage(url: player.api.dailyPodcastImageURL(player.segment?.imagePath), authorized: true) {
                        Text(player.segment?.icon ?? "🎙️").font(.title2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.indigo.opacity(0.15))
                    }
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: inTabAccessory ? artworkSize / 2 : 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.podcast?.title ?? "").font(.subheadline.bold()).lineLimit(1)
                        if !isCompact {
                            Text(player.segment?.caption ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Expand Podcast Player")
            .accessibilityIdentifier("podcast-mini-expand")
            Button { taps += 1; player.toggle() } label: {
                Label(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("podcast-mini-toggle")
            Button { taps += 1; player.close() } label: {
                Label("Close Player", systemImage: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("podcast-mini-close")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .padding(inTabAccessory ? EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 4) : EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .glassEffect(inTabAccessory ? .identity : .regular, in: .rect(cornerRadius: 24))
        .sensoryFeedback(.selection, trigger: taps)
    }

    private var artworkSize: CGFloat { inTabAccessory ? 32 : 44 }
}
