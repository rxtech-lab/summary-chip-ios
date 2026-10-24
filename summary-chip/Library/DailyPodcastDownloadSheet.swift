import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

struct DailyPodcastDownloadSheet: View {
    let api: SummaryAPIClient
    let podcast: DailyPodcast
    @Environment(\.dismiss) private var dismiss
    @State private var format: PodcastDownloadFormat = .audio
    @State private var preparing = false
    @State private var renderProgress: PodcastMotionRenderer.Progress?
    @State private var completed = false
    @State private var document: PodcastDownloadDocument?
    @State private var error: String?
    @State private var directory: URL?
    @State private var preparation: Task<Void, Never>?

    init(api: SummaryAPIClient, podcast: DailyPodcast, initialFormat: PodcastDownloadFormat = .audio) {
        self.api = api
        self.podcast = podcast
        _format = State(initialValue: initialFormat)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(PodcastDownloadFormat.allCases.filter { $0 != .video || podcast.video != nil }) { Text($0.title).tag($0) }
                    }
                    .disabled(preparing)
                    .accessibilityIdentifier("podcast-download-format")
                } footer: {
                    Text("Audio saves the complete podcast as MP3. Video saves the motion animation with selectable embedded captions as MP4. Captions saves a timed SRT subtitle file.")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Download Podcast")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if preparing { preparation?.cancel() } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { prepare() }
                        .disabled(preparing)
                        .accessibilityIdentifier("podcast-download-confirm")
                }
            }
            .overlay {
                if preparing || completed {
                    VStack(spacing: 12) {
                        if preparing {
                            if let fraction = renderProgress?.fraction {
                                ProgressView(value: fraction).frame(width: 180)
                                Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                            } else { ProgressView() }
                            if let detail = renderProgress?.frameDetail {
                                Text("Frames: \(detail)").monospacedDigit()
                                    .accessibilityIdentifier("podcast-download-frame-progress")
                            }
                            if renderProgress?.stage == .rendering { Text("Rendering video…") }
                            else if renderProgress?.stage == .encoding { Text("Encoding video…") }
                            else { Text("Preparing download…") }
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Downloaded")
                        }
                    }
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
            .task(id: completed) {
                guard completed else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { completed = false }
            }
            .interactiveDismissDisabled(preparing)
            .fileExporter(isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } }),
                          document: document, contentType: format.contentType, defaultFilename: filename) { result in
                switch result {
                case .success: completed = true
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .alert("Couldn't Download Podcast", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.selection, trigger: format)
            .sensoryFeedback(.success, trigger: completed)
            .sensoryFeedback(.error, trigger: error)
            .onDisappear {
                preparation?.cancel()
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 320, maxHeight: .infinity)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }

    private var filename: String {
        let safe = podcast.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "Podcast" : String(safe.prefix(120))) + "." + format.fileExtension
    }

    private func prepare() {
        renderProgress = nil
        preparing = true
        completed = false
        preparation = Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appending(path: "podcast-\(UUID().uuidString)", directoryHint: .isDirectory)
                if let directory { try? FileManager.default.removeItem(at: directory) }
                directory = folder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url: URL
                if format == .captions {
                    url = folder.appending(path: "podcast.srt")
                    try PodcastVideoExporter.subtitleData(for: podcast).write(to: url, options: .atomic)
                } else if format == .audio {
                    url = folder.appending(path: "podcast.mp3")
                    let bytes = try await api.dailyPodcastAudio(podcast)
                    try Task.checkCancellation()
                    try bytes.write(to: url, options: .atomic)
                } else if podcast.video != nil {
                    url = try await PodcastMotionRenderer.render(api: api, podcast: podcast) { renderProgress = $0 }
                } else {
                    throw SummaryAPIError.invalidResponse
                }
                try Task.checkCancellation()
                document = PodcastDownloadDocument(url: url)
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
            renderProgress = nil
            preparing = false
        }
    }
}

enum PodcastDownloadFormat: String, CaseIterable, Identifiable {
    case audio, video, captions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: String(localized: "Audio (MP3)")
        case .video: String(localized: "Video (MP4)")
        case .captions: String(localized: "Captions (SRT)")
        }
    }
    var fileExtension: String {
        switch self {
        case .audio: "mp3"
        case .video: "mp4"
        case .captions: "srt"
        }
    }
    var contentType: UTType {
        switch self {
        case .audio: .mp3
        case .video: .mpeg4Movie
        case .captions: UTType(filenameExtension: "srt") ?? .plainText
        }
    }
}

struct PodcastDownloadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mp3, .mpeg4Movie, UTType(filenameExtension: "srt") ?? .plainText] }
    let url: URL
    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: url, options: .immediate) }
}
