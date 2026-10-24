import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

struct DailyPodcastDownloadSheet: View {
    let api: SummaryAPIClient
    let podcast: DailyPodcast
    @Environment(\.dismiss) private var dismiss
    @State private var format: PodcastDownloadFormat = .audio
    @State private var preparing = false
    @State private var completed = false
    @State private var document: PodcastDownloadDocument?
    @State private var error: String?
    @State private var directory: URL?
    @State private var preparation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(PodcastDownloadFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(preparing)
                    .accessibilityIdentifier("podcast-download-format")
                } footer: {
                    Text("Audio saves the complete podcast as MP3. Video includes the cover images, speakers and captions as MP4.")
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
                        if preparing { ProgressView() } else { Image(systemName: "checkmark.circle.fill") }
                        Text(preparing ? "Preparing download…" : "Downloaded")
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
        preparing = true
        completed = false
        preparation = Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appending(path: "podcast-\(UUID().uuidString)", directoryHint: .isDirectory)
                if let directory { try? FileManager.default.removeItem(at: directory) }
                directory = folder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let audioURL = folder.appending(path: "podcast.mp3")
                let bytes = try await api.dailyPodcastAudio(podcast)
                try Task.checkCancellation()
                try bytes.write(to: audioURL, options: .atomic)
                let url = format == .audio ? audioURL : try await PodcastVideoExporter.export(api: api, podcast: podcast, audioURL: audioURL, directory: folder)
                try Task.checkCancellation()
                document = PodcastDownloadDocument(url: url)
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
            preparing = false
        }
    }
}

enum PodcastDownloadFormat: String, CaseIterable, Identifiable {
    case audio, video
    var id: String { rawValue }
    var title: String { self == .audio ? String(localized: "Audio (MP3)") : String(localized: "Video (MP4)") }
    var fileExtension: String { self == .audio ? "mp3" : "mp4" }
    var contentType: UTType { self == .audio ? .mp3 : .mpeg4Movie }
}

struct PodcastDownloadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mp3, .mpeg4Movie] }
    let url: URL
    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: url, options: .immediate) }
}
