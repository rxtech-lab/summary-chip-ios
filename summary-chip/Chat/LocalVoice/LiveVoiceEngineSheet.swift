#if os(macOS)
import LocalAgentKit
import Observation
import RxAgentClients
import RxAgentCore
import SummaryKit
import SwiftUI

/// Runner status and voice setup behind the sheet.
@MainActor @Observable
final class LocalVoiceSetupModel {
    private(set) var status: LocalAgentRunnerStatus?
    private(set) var isLoading = false
    private(set) var isPreparing = false
    private(set) var progress: LocalVoiceSetupProgress?
    var errorMessage: String?
    var modelActionInProgress = false
    private(set) var agentModels: [LocalAgentKind: [AgentModelOption]] = [:]
    private var setup: Task<Void, Never>?

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await LocalAgentRunnerClient.shared.status()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Once per sheet, so switching between agents doesn't ask again.
    func loadModels(for agent: LocalAgentKind) async {
        guard agentModels[agent] == nil else { return }
        do {
            agentModels[agent] = try await LocalAgentRunnerClient.shared.models(for: agent)
        } catch {
            // Only the runner being unreachable lands here; RxAgentSDK handles a CLI that can't answer.
            runnerLogger.error("Couldn't list \(agent.displayName, privacy: .public) models: \(error.localizedDescription, privacy: .public)")
            agentModels[agent] = switch agent {
            case .claudeCode: ClaudeCodeClient().fallbackModels
            case .codex: CodexClient().fallbackModels
            }
        }
    }

    func prepareVoice() {
        guard !isPreparing else { return }
        isPreparing = true
        LocalAgentRunnerClient.shared.onVoiceSetupProgress = { [weak self] in self?.progress = $0 }
        setup = Task {
            do {
                try await LocalAgentRunnerClient.shared.prepareVoice()
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparing = false
            progress = nil
            await refresh()
        }
    }

    func cancelVoiceSetup() {
        LocalAgentRunnerClient.shared.cancelVoiceSetup()
    }

    var progressMessage: String {
        switch progress?.phase {
        case .model:
            let percent = Int((progress?.fraction ?? 0) * 100)
            return String(localized: "Downloading the voice model… \(percent)%")
        default:
            return String(localized: "Installing the voice runtime…")
        }
    }
}

/// Chooses who answers in live voice. The pick is remembered for the next session.
struct LiveVoiceEngineSheet: View {
    @AppStorage(LiveVoiceSettings.engineKey) private var savedEngine = LiveVoiceEngine.chippy.rawValue
    @AppStorage(LiveVoiceSettings.languageKey) private var savedLanguage = ""
    @Environment(\.dismiss) private var dismiss
    @State private var setup = LocalVoiceSetupModel()
    @State private var selectionFeedback = 0
    @State private var showsModels = false

    private var engine: LiveVoiceEngine { LiveVoiceEngine(saved: savedEngine) }
    private var language: LocalVoiceLanguage { LocalVoiceLanguage.resolve(saved: savedLanguage.isEmpty ? nil : savedLanguage) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(LiveVoiceEngine.allCases) { row($0) }
                    if let agent = engine.localAgent, isAvailable(engine) {
                        AgentModelPicker(agent: agent, setup: setup).id(agent)
                    }
                } header: {
                    Text("Answered By")
                } footer: {
                    if engine.localAgent != nil {
                        Text("Local agents use their own account and limits. During voice they can read files and use your Chippy library, but other changes are denied unless you've already allowed them in the agent's settings.")
                    }
                }
                if engine.localAgent != nil { voiceSection }
            }
            .formStyle(.grouped)
            .navigationTitle("Voice Agent")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(setup.isPreparing)
                        .accessibilityIdentifier("voice-agent-done")
                }
                if setup.isPreparing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { setup.cancelVoiceSetup() }
                    }
                }
            }
            .overlay {
                if setup.isPreparing { ActionStatusOverlay(setup.progressMessage) }
            }
        }
        // A short macOS sheet would squeeze the navigation title, so keep it full height.
        .summarySheetSize()
        .interactiveDismissDisabled(setup.isPreparing)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sensoryFeedback(.success, trigger: setup.status?.voiceReady) { old, new in old == false && new == true }
        .statusAlert("Couldn't Set Up Local Voice", message: setup.errorMessage) { setup.errorMessage = nil }
        .sheet(isPresented: $showsModels, onDismiss: { Task { await setup.refresh() } }) { VoiceModelsSheet() }
        .task { await setup.refresh() }
    }

    private func row(_ option: LiveVoiceEngine) -> some View {
        Button {
            savedEngine = option.rawValue
            selectionFeedback += 1
        } label: {
            HStack(spacing: 12) {
                Image(systemName: option.symbolName).frame(width: 24).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).foregroundStyle(.primary)
                    Text(subtitle(option)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if engine == option {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable(option))
        .accessibilityIdentifier("voice-agent-\(option.rawValue)")
    }

    private func isAvailable(_ option: LiveVoiceEngine) -> Bool {
        guard let agent = option.localAgent else { return true }
        return setup.status?.install(for: agent)?.path != nil
    }

    private func subtitle(_ option: LiveVoiceEngine) -> String {
        guard let agent = option.localAgent else { return String(localized: "Cloud voice, uses your Chippy points") }
        guard let status = setup.status else { return String(localized: "Checking…") }
        guard let install = status.install(for: agent), install.path != nil else {
            return String(localized: "Not found. Install the \(agent.executableName) command to use it.")
        }
        return install.version ?? String(localized: "Installed")
    }

    private var voiceSection: some View {
        Section {
            Picker("Language", selection: Binding(get: { language.localeIdentifier }, set: { savedLanguage = $0 })) {
                ForEach(LocalVoiceLanguage.all) { option in
                    Text(Locale.current.localizedString(forIdentifier: option.localeIdentifier) ?? option.localeIdentifier)
                        .tag(option.localeIdentifier)
                }
            }
            .accessibilityIdentifier("voice-agent-language")
            if let modelID = setup.status?.selectedVoiceModel,
               let voices = LocalVoiceChoices.knownVoices(for: modelID), !voices.isEmpty {
                VoiceChoicePicker(modelID: modelID, voices: voices)
            }
            voiceStatusRow
        } header: {
            Text("On-Device Voice")
        } footer: {
            Text("Apple's speech recognition hears you and your selected voice model from Hugging Face replies, both on this Mac. The first session also creates a “Live Voice” API key so the agent can reach your library. You can revoke it in Settings → MCP Server.")
        }
    }

    private var voiceStatusRow: some View {
        LabeledContent("Voice Models") {
            Button("Manage…") { showsModels = true }
                .accessibilityIdentifier("voice-agent-download")
        }
    }

}

/// Picks the model one agent answers with. Sessions read it when they start.
private struct AgentModelPicker: View {
    let agent: LocalAgentKind
    let setup: LocalVoiceSetupModel
    @AppStorage private var saved: String

    init(agent: LocalAgentKind, setup: LocalVoiceSetupModel) {
        self.agent = agent
        self.setup = setup
        _saved = AppStorage(wrappedValue: "", LiveVoiceSettings.modelKey(for: agent))
    }

    private var models: [AgentModelOption] { setup.agentModels[agent] ?? [] }

    /// A pick the agent no longer lists stays visible rather than silently changing.
    private var options: [AgentModelOption] {
        saved.isEmpty || models.contains { $0.id == saved } ? models : models + [AgentModelOption(id: saved, displayName: saved)]
    }

    private var subtitle: String {
        if setup.agentModels[agent] == nil { return String(localized: "Checking available models…") }
        if saved.isEmpty { return String(localized: "Uses the model set in \(agent.displayName)") }
        return models.first { $0.id == saved }?.modelDescription ?? ""
    }

    var body: some View {
        Picker(selection: $saved) {
            Text("Agent Default").tag("")
            ForEach(options) { Text($0.displayName).tag($0.id) }
        } label: {
            Text("Model")
            if !subtitle.isEmpty { Text(subtitle) }
        }
        .sensoryFeedback(.selection, trigger: saved)
        .accessibilityIdentifier("voice-agent-model")
        .task { await setup.loadModels(for: agent) }
    }
}

extension LiveVoiceEngine {
    var title: String {
        switch self {
        case .chippy: "Chippy"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var symbolName: String {
        switch self {
        case .chippy: "cloud"
        case .claudeCode, .codex: "laptopcomputer"
        }
    }
}
#endif
