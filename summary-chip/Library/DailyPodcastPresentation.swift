import SummaryKit
import SwiftUI

/// The app owns playback; presentation and chip navigation never replace its audio player.
struct DailyPodcastPresentation: ViewModifier {
    let environment: AppEnvironment
    @State private var pendingChipID: String?
    @State private var openingChip = false
    @State private var error: String?
    @State private var openingTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        @Bindable var player = environment.podcastPlayer
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.podcast != nil, !player.isPresented {
                    DailyPodcastMiniPlayer(player: player)
                        .frame(maxWidth: 640)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
            }
            .sheet(isPresented: $player.isPresented, onDismiss: openPendingChip) {
                if let date = player.date {
                    DailyPodcastSheet(api: environment.api, date: date, player: player) { id in
                        pendingChipID = id
                        player.isPresented = false
                    }
                }
            }
            .overlay {
                if openingChip {
                    ProgressView("Opening chip…")
                        .padding(24)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
            .alert("Couldn't Open Chip", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .alert("Couldn't Play Podcast", isPresented: Binding(get: { !player.isPresented && player.error != nil }, set: { if !$0 { player.error = nil } })) {
                Button("OK", role: .cancel) { player.error = nil }
            } message: { Text(player.error ?? "") }
            .onDisappear { openingTask?.cancel() }
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

private struct DailyPodcastMiniPlayer: View {
    @Bindable var player: DailyPodcastPlayer
    @State private var taps = 0

    var body: some View {
        HStack(spacing: 8) {
            Button { taps += 1; player.isPresented = true } label: {
                HStack(spacing: 12) {
                    SummaryRemoteImage(url: player.api.dailyPodcastImageURL(player.segment?.imagePath), authorized: true) {
                        Text(player.segment?.icon ?? "🎙️").font(.title2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.indigo.opacity(0.15))
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.podcast?.title ?? "").font(.subheadline.bold()).lineLimit(1)
                        Text(player.segment?.caption ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .sensoryFeedback(.selection, trigger: taps)
    }
}
