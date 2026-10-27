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
                        .id(date)
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
            .onChange(of: environment.backgroundJobsRequest?.id) { _, request in
                if request != nil { player.isPresented = false }
            }
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

struct PodcastVersionsSheet: View {
    let api: SummaryAPIClient
    let date: Date
    /// A library podcast chip's versions instead of the day's.
    let summaryID: String?
    @Bindable var player: DailyPodcastPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [PodcastVersion] = []
    @State private var loading = true
    @State private var busy = false
    @State private var removing: DailyPodcast?
    @State private var error: String?
    @State private var successes = 0
    @State private var status: String?
    var body: some View {
        NavigationStack {
            List(versions) { version in
                VStack(alignment: .leading, spacing: 8) {
                    Text(version.podcast.title).font(.headline)
                    Text(version.podcast.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if version.isDefault { Label("Default", systemImage: "checkmark.circle.fill").font(.caption) }
                    HStack {
                        Button("Play", systemImage: "play.fill") {
                            player.replace(version.podcast); player.toggle(); dismiss()
                        }
                        if !version.isDefault {
                            Button("Set as Default") { update(version.podcast, remove: false) }
                                .font(.caption).fixedSize()
                        }
                        Spacer()
                        // A podcast chip always keeps one version; deleting the chip removes it.
                        if summaryID == nil || versions.count > 1 {
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = version.podcast }
                                .labelStyle(.iconOnly)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.subheadline)
                    .lineLimit(1)
                }
                .padding(.vertical, 6)
            }
            .disabled(busy)
            .overlay {
                if loading || busy {
                    ProgressView(busy ? "Updating podcasts…" : "Loading versions…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if versions.isEmpty { ContentUnavailableView("No Versions", systemImage: "waveform") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Podcast Versions")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy).accessibilityIdentifier("podcast-versions-done") } }
            .task { await reload(); loading = false }
            .confirmationDialog("Remove this podcast version?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove Version", role: .destructive) {
                    if let removing { update(removing, remove: true) }
                    removing = nil
                }
            } message: { Text("Its share links and translations will stop working. If it is the default, another version will become the default.") }
            .alert("Couldn't Update Podcasts", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .overlay(alignment: .top) {
                if let status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .padding().background(.regularMaterial, in: Capsule()).padding()
                        .allowsHitTesting(false)
                }
            }
            .interactiveDismissDisabled(busy)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
    private func reload() async {
        do { versions = try await loadVersions() }
        catch { self.error = error.localizedDescription }
    }
    private func loadVersions() async throws -> [PodcastVersion] {
        if let summaryID { return try await api.podcastVersions(summaryID: summaryID) }
        return try await api.podcastVersions(date: date)
    }
    private func update(_ podcast: DailyPodcast, remove: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if remove { try await api.removePodcast(podcast, date: date) }
                else { try await api.selectPodcast(podcast, date: date) }
                versions = try await loadVersions()
                if !remove {
                    player.replace(podcast); player.toggle()
                } else if player.podcast?.key == podcast.key {
                    player.stop()
                    if let next = versions.first(where: { $0.isDefault }) { player.replace(next.podcast) }
                    else { player.podcast = nil }
                }
                successes += 1
                status = remove ? "Version removed" : "Default updated"
                Task { try? await Task.sleep(for: .seconds(2)); status = nil }
            } catch { self.error = error.localizedDescription }
        }
    }
}


struct PodcastLinkedChipsSheet: View {
    let api: SummaryAPIClient
    let chipIDs: [String]
    let onOpenChip: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chips: [Summary] = []
    @State private var loading = true
    @State private var error: String?
    @State private var taps = 0

    var body: some View {
        NavigationStack {
            List(chips) { chip in
                Button { taps += 1; onOpenChip(chip.id) } label: {
                    Label(chip.title, systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .accessibilityIdentifier("podcast-linked-chip-\(chip.id)")
            }
            .overlay { if loading { ProgressView("Loading chips…") } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Linked Chips")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                defer { loading = false }
                do {
                    var loaded: [Summary] = []
                    for id in chipIDs { loaded.append(try await api.summary(id: id)) }
                    chips = loaded
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .alert("Couldn't Load Chips", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.selection, trigger: taps)
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}
