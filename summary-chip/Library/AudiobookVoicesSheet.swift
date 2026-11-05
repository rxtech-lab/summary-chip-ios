import AVFoundation
import Observation
import SummaryKit
import SwiftUI

/// Plays a voice's sample from storage. Only one plays at a time; the server draws each sample once.
@MainActor @Observable
final class AudiobookSamplePlayer {
    private(set) var loadingVoice: String?
    private(set) var playingVoice: String?
    var error: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func toggle(_ voice: String, language: SummaryLanguage, api: SummaryAPIClient) {
        if playingVoice == voice { stop(); return }
        stop()
        loadingVoice = voice
        Task {
            defer { if loadingVoice == voice { loadingVoice = nil } }
            do {
                let url = try await api.audiobookVoiceSample(voice: voice, language: language)
                guard loadingVoice == voice else { return }
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                let item = AVPlayerItem(url: url)
                let player = AVPlayer(playerItem: item)
                self.player = player
                observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stop() }
                }
                playingVoice = voice
                player.play()
            } catch { self.error = error.localizedDescription }
        }
    }

    func stop() {
        player?.pause()
        player = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        playingVoice = nil
        loadingVoice = nil
    }
}

/// The book's speakers, each with a voice. Automatic lets the agent cast them from the source.
struct AudiobookSpeakersSheet: View {
    let api: SummaryAPIClient
    let options: AudiobookOptions
    let language: SummaryLanguage
    let allowsAutomatic: Bool
    let onDone: ([AudiobookPlan.Speaker]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var automatic: Bool
    @State private var speakers: [AudiobookPlan.Speaker]
    /// The speaker whose voice is being chosen; nil index adds a new one.
    @State private var choosing: VoiceChoice?
    @State private var taps = 0

    private struct VoiceChoice: Identifiable { let id = UUID(); let index: Int? }

    init(api: SummaryAPIClient, options: AudiobookOptions, language: SummaryLanguage, allowsAutomatic: Bool, speakers: [AudiobookPlan.Speaker], onDone: @escaping ([AudiobookPlan.Speaker]) -> Void) {
        self.api = api; self.options = options; self.language = language; self.allowsAutomatic = allowsAutomatic; self.onDone = onDone
        _automatic = State(initialValue: allowsAutomatic && speakers.isEmpty)
        _speakers = State(initialValue: speakers)
    }

    private var valid: Bool {
        if automatic { return true }
        return !speakers.isEmpty && speakers.count <= options.speakers.maxCount
            && Set(speakers.map(\.voice)).count == speakers.count
            && speakers.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf16.count <= options.speakers.maxNameLength }
    }

    var body: some View {
        NavigationStack {
            Form {
                if allowsAutomatic {
                    Section {
                        Picker("Casting", selection: $automatic) {
                            Text("Automatic").tag(true)
                            Text("Custom").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("audiobook-speakers-mode")
                    } footer: {
                        if automatic { Text("The agent reads the source and casts a narrator, plus a voice for each major character or side when that helps.") }
                    }
                }
                if !automatic {
                    Section {
                        ForEach(speakers.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Name", text: $speakers[index].name)
                                    .accessibilityIdentifier("audiobook-speaker-name-\(index)")
                                if !speakers[index].role.isEmpty {
                                    Text(speakers[index].role).font(.caption).foregroundStyle(.secondary)
                                }
                                Button { taps += 1; choosing = VoiceChoice(index: index) } label: {
                                    LabeledContent("Voice") {
                                        HStack(spacing: 6) {
                                            Text(options.voice(speakers[index].voice)?.name ?? speakers[index].voice)
                                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("audiobook-speaker-voice-\(index)")
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { speakers.remove(atOffsets: $0); taps += 1 }
                        if speakers.count < options.speakers.maxCount {
                            Button { taps += 1; choosing = VoiceChoice(index: nil) } label: {
                                Label("Add Speaker", systemImage: "plus")
                            }
                            .accessibilityIdentifier("audiobook-speaker-add")
                        }
                    } header: { Text("Speakers") } footer: {
                        Text("Each speaker needs a different voice, up to \(options.speakers.maxCount).")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Speakers")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(automatic ? [] : speakers.map { speaker in
                            var trimmed = speaker
                            trimmed.name = speaker.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            return trimmed
                        })
                        dismiss()
                    }
                    .disabled(!valid)
                    .accessibilityIdentifier("audiobook-speakers-done")
                }
            }
            .sheet(item: $choosing) { choice in
                AudiobookVoicePickerSheet(api: api, options: options, language: language,
                    selected: choice.index.map { speakers[$0].voice },
                    taken: Set(speakers.enumerated().filter { $0.offset != choice.index }.map(\.element.voice))) { voice in
                    if let index = choice.index {
                        // A name still matching the old voice follows the new one.
                        if speakers[index].name == options.voice(speakers[index].voice)?.name { speakers[index].name = voice.name }
                        speakers[index].voice = voice.id
                    } else {
                        speakers.append(.init(name: voice.name, voice: voice.id))
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.selection, trigger: automatic)
        }
        .frame(minWidth: 360, idealWidth: 520, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
}

/// Every voice with a Play Sample control, by provider. Picking one closes the sheet.
struct AudiobookVoicePickerSheet: View {
    let api: SummaryAPIClient
    let options: AudiobookOptions
    let language: SummaryLanguage
    let selected: String?
    let taken: Set<String>
    let onChoose: (AudiobookVoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var samples = AudiobookSamplePlayer()
    @State private var taps = 0

    private func voices(_ provider: String) -> [AudiobookVoice] { options.voices.filter { $0.provider == provider } }

    var body: some View {
        NavigationStack {
            List {
                section("ElevenLabs", provider: "elevenlabs")
                section("Azure", provider: "azure")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Choose Voice")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Couldn't Play Sample", isPresented: Binding(get: { samples.error != nil }, set: { if !$0 { samples.error = nil } })) {
                Button("OK", role: .cancel) { samples.error = nil }
            } message: { Text(samples.error ?? "") }
            .onDisappear { samples.stop() }
            .sensoryFeedback(.selection, trigger: taps)
            .sensoryFeedback(.impact, trigger: samples.playingVoice)
            .sensoryFeedback(.error, trigger: samples.error)
        }
        .frame(minWidth: 360, idealWidth: 480, minHeight: 480, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey, provider: String) -> some View {
        let list = voices(provider)
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { voice in row(voice) }
            }
        }
    }

    private func row(_ voice: AudiobookVoice) -> some View {
        HStack(spacing: 12) {
            Button { taps += 1; samples.toggle(voice.id, language: language, api: api) } label: {
                Group {
                    if samples.loadingVoice == voice.id { ProgressView().controlSize(.small) }
                    else { Image(systemName: samples.playingVoice == voice.id ? "stop.circle.fill" : "play.circle.fill").font(.title2).foregroundStyle(.tint) }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(samples.playingVoice == voice.id ? "Stop Sample" : "Play Sample")
            .accessibilityIdentifier("audiobook-voice-sample-\(voice.name)")
            Button {
                taps += 1
                samples.stop()
                onChoose(voice)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).font(.body)
                        Text(voice.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if voice.id == selected { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                    else if taken.contains(voice.id) { Text("In use").font(.caption).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(taken.contains(voice.id))
            .accessibilityIdentifier("audiobook-voice-\(voice.name)")
        }
        .padding(.vertical, 2)
    }
}
