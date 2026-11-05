#if os(macOS)
import AgentMarkdownUI
import LocalAgentKit
import SummaryKit
import SwiftUI

/// Hugging Face browser: the model list in the sidebar, the selected model in the detail.
struct VoiceModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var setup = LocalVoiceSetupModel()
    @State private var query = ""
    @State private var section = "Browse"
    @State private var selection: String?
    @State private var results: [VoiceHubResult] = []
    @State private var nextPage: URL?
    @State private var loading = true
    @State private var searchError: String?
    @State private var retry = 0
    @State private var pendingDelete: LocalVoiceModel?
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var deleted = 0

    private var installed: [LocalVoiceModel] {
        (setup.status?.voiceModels ?? []).filter { setup.status?.storedVoiceModels.contains($0.id) == true }
    }
    private var matchingInstalled: [LocalVoiceModel] {
        installed.filter { query.isEmpty || $0.repository.localizedCaseInsensitiveContains(query) }
    }
    private var selectedInstalled: LocalVoiceModel? {
        installed.first { $0.repository == selection }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Models", selection: $section) {
                    Text("Browse").tag("Browse")
                    Text("Downloaded").tag("Downloaded")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                modelList
            }
            .navigationTitle("Voice Models")
            .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
            .toolbar(removing: .sidebarToggle)
            .disabled(setup.modelActionInProgress)
        } detail: {
            Group {
                if let selection {
                    VoiceHubDetail(repository: selection, installed: selectedInstalled,
                                   summary: results.first { $0.id == selection }, setup: setup)
                        .id(selection)
                } else {
                    ContentUnavailableView("Choose a Voice Model", systemImage: "waveform", description: Text("Search Hugging Face or select a downloaded model."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(setup.modelActionInProgress) } }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $query, placement: .sidebar, prompt: "Search Hugging Face models")
        .frame(minWidth: 960, idealWidth: 1080, maxWidth: .infinity, minHeight: 640, idealHeight: 760, maxHeight: .infinity)
        .interactiveDismissDisabled(setup.modelActionInProgress)
        .overlay {
            if deleting { ActionStatusOverlay(String(localized: "Deleting model…")) }
        }
        .confirmationDialog("Delete downloaded model?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { model in
            Button("Delete Model", role: .destructive) { delete(model) }
        } message: { model in
            Text(setup.status?.selectedVoiceModel == model.id ? "This is your selected model. Download it again or select another model before using local voice." : "The model files will be removed from this Mac. You can download them again.")
        }
        .statusAlert("Couldn't Update Voice Model", message: deleteError) { deleteError = nil }
        .sensoryFeedback(.success, trigger: deleted)
        .task { await setup.refresh() }
        .task(id: "\(query)|\(retry)") {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await search()
        }
        .statusAlert("Couldn't Load Voice Models", message: setup.errorMessage) { setup.errorMessage = nil }
    }

    private var modelList: some View {
        List(selection: $selection) {
            if section == "Downloaded" {
                ForEach(matchingInstalled) { model in
                    VoiceModelRow(title: model.title, subtitle: installedStatus(model))
                        .tag(model.repository)
                        .contextMenu { deleteMenuItem(model) }
                }
            } else {
                ForEach(results) { result in
                    VoiceModelRow(title: result.id.components(separatedBy: "/").last ?? result.id,
                                  subtitle: result.id.components(separatedBy: "/").first ?? "",
                                  downloads: result.downloads ?? 0,
                                  likes: result.likes ?? 0)
                        .tag(result.id)
                        .contextMenu {
                            if let model = installed.first(where: { $0.repository == result.id }) { deleteMenuItem(model) }
                        }
                }
                if !results.isEmpty { pagingRow }
            }
        }
        .overlay { listPlaceholder }
        .accessibilityIdentifier("voice-model-sidebar")
    }

    /// Sits at the end of a list that already has results, so the rows above stay in place.
    @ViewBuilder private var pagingRow: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
            } else if let searchError {
                VStack(spacing: 6) {
                    Text(searchError).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { retry += 1 }
                }
            } else if let nextPage {
                Button("Load More") { Task { await search(next: nextPage) } }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// Fills the list and centers in it, for when there are no rows to show yet.
    @ViewBuilder private var listPlaceholder: some View {
        if section == "Downloaded" {
            if matchingInstalled.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Downloaded Models", systemImage: "arrow.down.circle", description: Text("Models you download from Browse appear here."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        } else if results.isEmpty {
            if let searchError {
                ContentUnavailableView {
                    Label("Couldn't Load Models", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(searchError)
                } actions: {
                    Button("Retry") { retry += 1 }
                }
            } else if loading {
                ProgressView("Searching Hugging Face…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.isEmpty {
                ContentUnavailableView("No Voice Models", systemImage: "waveform", description: Text("No matching MLX speech models."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func deleteMenuItem(_ model: LocalVoiceModel) -> some View {
        Button("Delete Model…", systemImage: "trash", role: .destructive) { pendingDelete = model }
    }

    private func delete(_ model: LocalVoiceModel) {
        deleting = true
        setup.modelActionInProgress = true
        Task {
            do {
                try await LocalAgentRunnerClient.shared.manageVoiceModel(id: model.id, action: "delete")
                deleted += 1
            } catch { deleteError = error.localizedDescription }
            await setup.refresh()
            deleting = false
            setup.modelActionInProgress = false
        }
    }

    private func installedStatus(_ model: LocalVoiceModel) -> String {
        if setup.status?.selectedVoiceModel == model.id { return String(localized: "Selected") }
        if setup.status?.downloadedVoiceModels.contains(model.id) == true { return String(localized: "Downloaded") }
        return String(localized: "Incomplete download")
    }

    private func search(next: URL? = nil) async {
        let searched = query
        loading = true
        searchError = nil
        if next == nil { results = []; nextPage = nil }
        do {
            let page = try await VoiceModelHub.search(searched, next: next)
            try Task.checkCancellation()
            guard searched == query else { return }
            let existing = Set(results.map(\.id))
            results += page.models.filter { !existing.contains($0.id) }
            nextPage = page.next
        } catch is CancellationError { return }
        catch { if !Task.isCancelled, searched == query { searchError = error.localizedDescription } }
        if searched == query { loading = false }
    }
}

/// Rounded tile standing in for a model's artwork.
private struct VoiceModelIcon: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct VoiceModelStat: View {
    let systemImage: String
    let value: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).imageScale(.small)
            Text(value.formatted(.number.notation(.compactName)))
        }
        .fixedSize()
    }
}

private struct VoiceModelRow: View {
    let title: String
    let subtitle: String
    var downloads: Int?
    var likes: Int?

    var body: some View {
        HStack(spacing: 10) {
            VoiceModelIcon(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle).help(title)
                HStack(spacing: 8) {
                    Text(subtitle).lineLimit(1)
                    if let downloads { VoiceModelStat(systemImage: "arrow.down", value: downloads) }
                    if let likes { VoiceModelStat(systemImage: "heart", value: likes) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct VoiceHubDetail: View {
    let repository: String
    let installed: LocalVoiceModel?
    let summary: VoiceHubResult?
    let setup: LocalVoiceSetupModel
    @State private var model: LocalVoiceModel?
    @State private var readme: String?
    @State private var readmeError: String?
    @State private var resolutionError: String?
    @State private var loading = true
    @State private var tab = "README"
    @State private var action: String?
    @State private var cancelling = false
    @State private var progress: LocalVoiceSetupProgress?
    @State private var errorMessage: String?
    @State private var confirmsDelete = false
    @State private var completed = 0
    @State private var retry = 0
    @State private var voices: [String] = []
    @State private var voicesFromReadme = false
    @State private var checkingVoices = false
    @State private var voiceCheckError: String?
    @State private var voiceRecheck = 0
    @State private var sample = VoiceSamplePlayer()
    private var current: LocalVoiceModel? { model ?? installed }
    private var downloaded: Bool { current.map { setup.status?.downloadedVoiceModels.contains($0.id) == true } ?? false }
    private var stored: Bool { current.map { setup.status?.storedVoiceModels.contains($0.id) == true } ?? false }
    private var selected: Bool { current?.id == setup.status?.selectedVoiceModel }
    private var repositoryURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
    private var size: String { current?.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "Calculating…") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("View", selection: $tab) {
                Text("README").tag("README")
                Text("Details").tag("Details")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 12)
            Divider()
            Group {
                if tab == "README" { readmePane } else { detailsPane }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("voice-model-detail")
        .disabled(action != nil || sample.phase != .idle)
        .overlay { actionOverlay }
        .overlay { sampleOverlay }
        .onDisappear { sample.shutdown() }
        .statusAlert("Couldn't Play Sample", message: sample.errorMessage) { sample.errorMessage = nil }
        .confirmationDialog("Delete downloaded model?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Model", role: .destructive) { perform("delete") }
        } message: {
            Text(selected ? "This is your selected model. Download it again or select another model before using local voice." : "The model files will be removed from this Mac. You can download them again.")
        }
        .statusAlert("Couldn't Update Voice Model", message: errorMessage) { errorMessage = nil }
        .sensoryFeedback(.success, trigger: completed)
        .task(id: retry) {
            async let card: Void = loadReadme()
            await loadModel()
            await card
        }
        .task(id: "\(tab)|\(current?.id ?? "")|\(readme != nil)|\(voiceRecheck)") {
            if tab == "Details" { await loadVoices() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VoiceModelIcon(size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(repository.components(separatedBy: "/").last ?? repository)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Link(repository, destination: repositoryURL)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 12) {
                        Text("MLX · Text to Speech")
                        if let summary {
                            VoiceModelStat(systemImage: "arrow.down", value: summary.downloads ?? 0)
                            VoiceModelStat(systemImage: "heart", value: summary.likes ?? 0)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                primaryAction
            }
            if let unavailableReason {
                Label(unavailableReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One place for the model's main action, so it stays put when switching tabs.
    @ViewBuilder private var primaryAction: some View {
        Group {
            if downloaded, selected {
                Label("In Use", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else if downloaded {
                Button("Use for Voice Chat") { perform("select") }
                    .buttonStyle(.borderedProminent)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(stored ? "Resume Download" : "Download") { perform("download") }
                        .buttonStyle(.borderedProminent)
                        .disabled(loading || model == nil || setup.status?.hasUV != true || setup.status?.isAppleSilicon != true)
                    if current != nil {
                        Text(size).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .controlSize(.large)
        .fixedSize()
    }

    private var unavailableReason: String? {
        guard !downloaded else { return nil }
        if setup.status?.isAppleSilicon == false { return String(localized: "Requires a Mac with Apple silicon.") }
        if setup.status?.hasUV == false { return String(localized: "Install uv with “brew install uv” to prepare the speech runtime.") }
        return nil
    }

    // MARK: - Tabs

    @ViewBuilder private var readmePane: some View {
        if let readme {
            ScrollView {
                MarkdownView(text: readme, baseURL: repositoryURL.appending(path: "resolve/\(current?.revision ?? "main")/"))
                    .textSelection(.enabled)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            }
        } else if let readmeError {
            ContentUnavailableView {
                Label("README Unavailable", systemImage: "doc.text")
            } description: {
                Text(readmeError)
            } actions: {
                Link("Read on Hugging Face", destination: repositoryURL)
            }
        } else {
            ProgressView("Loading model card…")
        }
    }

    @ViewBuilder private var detailsPane: some View {
        if let current {
            Form {
                Section("Model") {
                    LabeledContent("Download size", value: size)
                    LabeledContent("Files", value: current.files.count.formatted())
                    LabeledContent("Architecture", value: current.family)
                }
                voiceSection(current)
                Section {
                    LabeledContent("Status", value: storageStatus)
                    if stored {
                        LabeledContent("Model Files") {
                            Button("Delete Model…", role: .destructive) { confirmsDelete = true }
                        }
                    }
                } header: {
                    Text("On This Mac")
                } footer: {
                    Text("Model files are downloaded from Hugging Face to Application Support. The shared speech runtime is an additional download on first use. Playback depends on MLX Audio support; some models require reference audio or voice instructions. End voice chat before changing models.")
                }
            }
            .formStyle(.grouped)
        } else if let resolutionError {
            ContentUnavailableView {
                Label("Couldn't Check This Model", systemImage: "exclamationmark.triangle")
            } description: {
                Text(resolutionError)
            } actions: {
                Button("Retry") { retry += 1 }
            }
        } else {
            ProgressView("Checking files and download size…")
        }
    }

    private func voiceSection(_ current: LocalVoiceModel) -> some View {
        Section {
            if !voices.isEmpty {
                VoiceChoicePicker(modelID: current.id, voices: voices)
            }
            if checkingVoices {
                LabeledContent("Available Voices") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the README…")
                    }
                }
            } else if voices.isEmpty, voiceCheckError == nil {
                LabeledContent("Available Voices", value: readmeError != nil && voicesFromReadme ? String(localized: "README unavailable") : String(localized: "None listed"))
            }
            if showsSeed { VoiceSeedPicker(modelID: current.id) }
            if downloaded, !checkingVoices {
                LabeledContent("Sample") {
                    Button("Play Sample", systemImage: "play.fill") {
                        sample.play(modelID: current.id, seed: LocalVoiceChoices.chosenSeed(for: current.id),
                                    voice: LocalVoiceChoices.chosenVoice(for: current.id))
                    }
                    .accessibilityIdentifier("voice-model-play-sample")
                }
            }
            if voicesFromReadme, !checkingVoices {
                LabeledContent("README") {
                    Button("Check Again") {
                        LocalVoiceChoices.forgetVoices(for: current.id)
                        voiceRecheck += 1
                    }
                }
            }
        } header: {
            Text("Voice")
        } footer: {
            if let voiceCheckError {
                Text(voiceCheckError)
            } else if showsSeed {
                Text("Each seed gives this model a different voice. Play a sample to hear it. Your choice applies from the next voice chat.")
            } else if !voices.isEmpty, voicesFromReadme {
                Text("Found in the README by Apple Intelligence on this Mac. If the model doesn't accept a voice, it speaks in its default voice instead. Your choice applies from the next voice chat.")
            } else if !voices.isEmpty {
                Text("Listed in the model's files. Your choice applies from the next voice chat.")
            } else {
                Text("This model speaks in its default voice.")
            }
        }
    }

    /// Models with preset voices are adjusted by picking one instead.
    private var showsSeed: Bool { downloaded && voices.isEmpty && !checkingVoices }

    @ViewBuilder private var sampleOverlay: some View {
        switch sample.phase {
        case .idle:
            EmptyView()
        case .preparing:
            ActionStatusOverlay(String(localized: "Preparing sample…"), cancelTitle: "Stop") { sample.stop() }
        case .playing:
            ActionStatusOverlay(String(localized: "Playing sample…"), isWorking: false, cancelTitle: "Stop") { sample.stop() }
        }
    }

    private var storageStatus: String {
        if downloaded { return selected ? String(localized: "Selected for voice chat") : String(localized: "Downloaded") }
        return stored ? String(localized: "Incomplete download") : String(localized: "Not downloaded")
    }

    // MARK: - Action

    @ViewBuilder private var actionOverlay: some View {
        switch action {
        case "download":
            if cancelling {
                ActionStatusOverlay(String(localized: "Cancelling download…"))
            } else {
                ActionStatusOverlay(downloadMessage, progress: progress?.phase == .model ? progress?.fraction ?? 0 : nil, cancelTitle: "Cancel Download") {
                    cancelling = true
                    LocalAgentRunnerClient.shared.cancelVoiceSetup()
                }
            }
        case "delete":
            ActionStatusOverlay(String(localized: "Deleting model…"))
        case "select":
            ActionStatusOverlay(String(localized: "Selecting model…"))
        default:
            EmptyView()
        }
    }

    private var downloadMessage: String {
        if progress?.phase == .model {
            let percent = Int((progress?.fraction ?? 0) * 100)
            return String(localized: "Downloading \(size)… \(percent)%")
        }
        return String(localized: "Preparing model and speech runtime…")
    }

    /// The model's own files are authoritative. Only without them is the README worth asking about.
    private func loadVoices() async {
        guard let current else { return }
        if let preset = current.presetVoices, !preset.isEmpty {
            voices = preset
            voicesFromReadme = false
            LocalVoiceChoices.remember(preset, for: current.id)
            return
        }
        voicesFromReadme = true
        if let known = LocalVoiceChoices.knownVoices(for: current.id) {
            voices = known
            return
        }
        guard let readme else { return }
        checkingVoices = true
        voiceCheckError = nil
        defer { checkingVoices = false }
        do {
            let found = try await VoiceReadmeReader.voices(in: readme)
            try Task.checkCancellation()
            voices = found
            LocalVoiceChoices.remember(found, for: current.id)
        } catch { if !Task.isCancelled { voiceCheckError = error.localizedDescription } }
    }

    private func loadModel() async {
        loading = true
        resolutionError = nil
        do {
            var result = try await VoiceModelHub.resolve(repository, revision: installed?.revision)
            if let installed { result.id = installed.id }
            try Task.checkCancellation()
            model = result
        } catch { if !Task.isCancelled { resolutionError = error.localizedDescription } }
        loading = false
    }

    private func loadReadme() async {
        do {
            let text = try await VoiceModelHub.readme(repository, revision: installed?.revision ?? "main")
            try Task.checkCancellation()
            readme = text
        } catch { if !Task.isCancelled { readmeError = error.localizedDescription } }
    }

    private func perform(_ operation: String) {
        guard action == nil, let current else { return }
        // The runner won't change models while one is loaded for samples.
        sample.shutdown()
        action = operation
        setup.modelActionInProgress = true
        LocalAgentRunnerClient.shared.onVoiceSetupProgress = { progress = $0 }
        Task {
            do {
                if operation == "download" { try await LocalAgentRunnerClient.shared.downloadVoiceModel(current) }
                else { try await LocalAgentRunnerClient.shared.manageVoiceModel(id: current.id, action: operation) }
                if !cancelling {
                    completed += 1
                    if operation != "delete" { await loadVoices() }
                }
            } catch {
                // Stopping a download on request isn't a failure worth an alert.
                if !cancelling { errorMessage = error.localizedDescription }
            }
            await setup.refresh()
            LocalAgentRunnerClient.shared.onVoiceSetupProgress = nil
            progress = nil
            action = nil
            cancelling = false
            setup.modelActionInProgress = false
        }
    }
}
#endif
