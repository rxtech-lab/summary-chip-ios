import AVFoundation
import Observation
import SummaryKit
import SwiftUI

struct DailyPodcastSheet: View {
    let api: SummaryAPIClient
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @Bindable var player: DailyPodcastPlayer
    let onOpenChip: (String) -> Void
    @State private var loading = true
    @State private var showsGeneration = false
    @State private var showsDownload = false
    @State private var showsSharing = false
    @State private var error: String?
    @State private var taps = 0

    var body: some View {
        playerLayout
            .overlay {
                if loading || player.buffering {
                    ProgressView(loading ? "Loading podcast…" : "Loading audio…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(isPresented: $showsGeneration) {
                DailyPodcastGenerationSheet(api: api, date: date, existing: player.podcast) { podcast in
                    guard player.date == date else { return }
                    player.replace(podcast)
                    player.toggle()
                }
            }
            .sheet(isPresented: $showsDownload) {
                if let podcast = player.podcast {
                    DailyPodcastDownloadSheet(api: api, podcast: podcast)
                }
            }
            .sheet(isPresented: $showsSharing) {
                if let podcast = player.podcast {
                    DailyPodcastSharingSheet(api: api, podcast: podcast)
                }
            }
            .alert("Couldn't Load Podcast", isPresented: Binding(get: { error != nil || player.error != nil }, set: { if !$0 { error = nil; player.error = nil } })) {
                Button("OK", role: .cancel) { error = nil; player.error = nil }
            } message: { Text(error ?? player.error ?? "") }
            .task {
                if player.podcast == nil {
                    do {
                        if let saved = try await api.dailyPodcast(date: date), !Task.isCancelled, player.date == date {
                            player.replace(saved)
                        }
                    }
                    catch is CancellationError {} catch { self.error = error.localizedDescription }
                }
                loading = false
            }
            .sensoryFeedback(.selection, trigger: taps)
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 760, minHeight: 480, maxHeight: .infinity)
        #else
        .frame(minWidth: 320, idealWidth: 640, minHeight: 520, maxHeight: .infinity)
        #endif
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var playerLayout: some View {
        #if os(macOS)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                macPlayerBar
            }
        #else
        NavigationStack {
            content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(date.formatted(date: .abbreviated, time: .omitted))
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if player.podcast != nil {
                    ToolbarItem(placement: .confirmationAction) { podcastActions }
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private var macPlayerBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button("Done") { dismiss() }
                if player.podcast != nil {
                    Spacer(minLength: 8)
                    Button {
                        guard let id = player.segment?.chipId else { return }
                        onOpenChip(id)
                    } label: { Label("Open Chip", systemImage: "doc.text.magnifyingglass") }
                    .accessibilityIdentifier("podcast-open-chip")
                    podcastActions
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                } else { Spacer() }
            }
            .buttonStyle(MacPlayerGlassButtonStyle())
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
        }
        .environment(\.colorScheme, .dark)
        .padding(12)
    }
    #endif

    private var podcastActions: some View {
        Menu {
            Button { taps += 1; showsSharing = true } label: {
                Label("Publish to Web", systemImage: "square.and.arrow.up")
            }.accessibilityIdentifier("podcast-publish")
            Button { player.stop(); showsGeneration = true } label: {
                Label("Regenerate Podcast", systemImage: "arrow.clockwise")
            }.accessibilityIdentifier("podcast-regenerate")
            Button { showsDownload = true } label: {
                Label("Download Podcast", systemImage: "arrow.down.to.line")
            }.accessibilityIdentifier("podcast-download")
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("podcast-more")
    }

    @ViewBuilder
    private var content: some View {
        if let podcast = player.podcast, player.segment != nil {
            DailyPodcastPlaybackView(api: api, podcast: podcast, player: player, onOpenChip: onOpenChip)
        } else if !loading {
            ContentUnavailableView {
                Label("Daily Podcast", systemImage: "waveform")
            } description: {
                Text("Turn this day's chips into a podcast with captions and artwork. Choose a language before generating.")
            } actions: {
                Button("Generate Podcast") { showsGeneration = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("podcast-generate")
            }
        } else {
            Color.clear
        }
    }

}

#if os(macOS)
/// Liquid Glass capsule for the controls floating over the podcast artwork. The padding lives
/// inside the style so the whole capsule, not just the label, is clickable (menus included).
private struct MacPlayerGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(minWidth: 34, minHeight: 34)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
#endif

private struct DailyPodcastGenerationSheet: View {
    let api: SummaryAPIClient
    let date: Date
    let existing: DailyPodcast?
    let onGenerated: (DailyPodcast) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var language: SummaryLanguage = .en
    @State private var generating = false
    @State private var confirmsRegeneration = false
    @State private var error: String?
    @State private var successes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(SummaryLanguage.translations) { Text($0.title).tag($0) }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Includes all readable summary chips saved or opened on this day, across feed filters. The agent chooses the hosts. Up to 24 chips per episode.")
                        #if os(macOS)
                        generationNotice
                        #endif
                    }
                }
                #if os(iOS)
                Section {
                    generationButton
                } footer: {
                    generationNotice
                }
                #endif
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(existing == nil ? "New Podcast" : "Regenerate Podcast")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(generating)
                }
                #if os(macOS)
                ToolbarItem(placement: .confirmationAction) {
                    generationButton.keyboardShortcut(.defaultAction)
                }
                #endif
            }
            .disabled(generating)
            .overlay {
                if generating {
                    ProgressView("Creating your podcast…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .interactiveDismissDisabled(generating)
            .confirmationDialog("Replace this day's podcast?", isPresented: $confirmsRegeneration, titleVisibility: .visible) {
                Button("Regenerate Podcast") { generate() }
            } message: { Text("This uses points. Your saved episode stays available if generation fails.") }
            .alert("Couldn't Generate Podcast", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onAppear {
                language = existing.flatMap { SummaryLanguage(rawValue: $0.language) }
                    ?? SummaryLanguage(languageTag: Locale.preferredLanguages.first ?? "en") ?? .en
            }
            .sensoryFeedback(.impact, trigger: generating)
            .sensoryFeedback(.selection, trigger: language)
            .sensoryFeedback(.success, trigger: successes)
            .sensoryFeedback(.error, trigger: error)
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 320, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private var generationButton: some View {
        Button(existing == nil ? "Generate Podcast" : "Regenerate Podcast") {
            if existing != nil { confirmsRegeneration = true } else { generate() }
        }
        .disabled(generating)
        .accessibilityIdentifier("podcast-generation-submit")
    }

    private var generationNotice: some View {
        Text("Generation uses points. Audio is saved for future playback. Regeneration creates a new episode using the current chips and selected language.")
    }

    private func generate() {
        generating = true
        Task {
            do {
                let podcast = try await api.generateDailyPodcast(date: date, language: language, regenerate: existing != nil)
                successes += 1
                onGenerated(podcast)
                dismiss()
            } catch { self.error = error.localizedDescription }
            generating = false
        }
    }
}
