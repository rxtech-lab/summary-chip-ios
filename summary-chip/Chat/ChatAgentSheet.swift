import LocalAgentKit
import SummaryKit
import SwiftUI

struct ChatAgentSelection {
    static let providerKey = "chatAgentProvider"
    static let cloud = "flowcy"
    static func modelKey(for agent: LocalAgentKind) -> String { "chatAgentModel.\(agent.rawValue)" }

    #if os(macOS)
    let localAgent: LocalAgentKind?
    let localModelID: String?

    init(defaults: UserDefaults = .standard) {
        localAgent = defaults.string(forKey: Self.providerKey).flatMap(LocalAgentKind.init(rawValue:))
        localModelID = localAgent.flatMap { defaults.string(forKey: Self.modelKey(for: $0)) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    #endif
}

/// The composer and both model pickers show the same account selection after a successful save.
@Observable
final class FlowcyModelSelection {
    private let api: SummaryAPIClient
    private var loadTask: Task<Void, Error>?
    private(set) var models: [FlowcyModel]?
    private(set) var selectedID: String?
    private(set) var isSaving = false
    var isLoading: Bool { loadTask != nil }

    init(api: SummaryAPIClient) { self.api = api }

    var displayName: String {
        guard let models else { return String(localized: "Model") }
        guard let selectedID else { return String(localized: "Automatic") }
        return models.first { $0.id == selectedID }?.alias ?? selectedID
    }

    func load() async throws {
        if let loadTask { return try await loadTask.value }
        guard !isSaving else { return }
        let task = Task {
            defer { loadTask = nil }
            let catalog = try await api.flowcyModels()
            models = catalog.models
            selectedID = catalog.selectedModelId
        }
        loadTask = task
        try await task.value
    }

    func select(_ id: String?) async throws {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // Let the current read finish before saving. Automatic can still be saved if the catalog is down.
        if let loadTask { _ = await loadTask.result }
        try await api.selectFlowcyModel(id)
        selectedID = id
    }
}

struct ChatModelPickerButton: View {
    let cloud: FlowcyModelSelection
    let controlSize: CGFloat
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @AppStorage(ChatAgentSelection.providerKey) private var provider = ChatAgentSelection.cloud
    @AppStorage(ChatAgentSelection.modelKey(for: .codex)) private var codexModel = ""
    @AppStorage(ChatAgentSelection.modelKey(for: .claudeCode)) private var claudeModel = ""
    #endif

    private var localAgent: LocalAgentKind? {
        #if os(macOS)
        LocalAgentKind(rawValue: provider)
        #else
        nil
        #endif
    }

    private var modelTitle: String {
        #if os(macOS)
        if let agent = localAgent {
            let modelID = agent == .codex ? codexModel : claudeModel
            return modelID.isEmpty ? agent.displayName : "\(agent.displayName) · \(modelID)"
        }
        #endif
        return cloud.displayName
    }

    var body: some View {
        let title = modelTitle
        let showCloudModel = localAgent == nil && scenePhase == .active
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: localAgent == nil ? "cloud" : "laptopcomputer")
                    .foregroundStyle(.secondary)
                Text(verbatim: title).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 8)
            .frame(minHeight: controlSize)
            .contentShape(Rectangle())
        }
        .help("Choose an AI model")
        .accessibilityLabel("AI Models")
        .accessibilityValue(title)
        .accessibilityIdentifier("chat-ai-models")
        .task(id: showCloudModel) {
            if showCloudModel { try? await cloud.load() }
        }
    }
}

struct ChatAgentSheet: View {
    let cloud: FlowcyModelSelection
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var feedback = 0
    #if os(macOS)
    @AppStorage(ChatAgentSelection.providerKey) private var provider = ChatAgentSelection.cloud
    @State private var setup = LocalVoiceSetupModel()
    #endif

    var body: some View {
        NavigationStack {
            Form {
                #if os(macOS)
                Section {
                    Picker("Provider", selection: $provider) {
                        Text("Flowcy Cloud").tag(ChatAgentSelection.cloud)
                        ForEach(LocalAgentKind.allCases, id: \.self) { agent in
                            let installed = setup.status?.install(for: agent)?.path != nil
                            Text(installed ? agent.displayName : "\(agent.displayName) · \(setup.isLoading ? String(localized: "Checking…") : String(localized: "Not installed"))")
                                .tag(agent.rawValue).disabled(!installed)
                        }
                    }
                    .accessibilityIdentifier("chat-agent-provider")
                    if let agent = LocalAgentKind(rawValue: provider) {
                        AgentModelPicker(agent: agent, setup: setup, modelKey: ChatAgentSelection.modelKey(for: agent),
                                         identifier: "chat-local-model").id(agent)
                    }
                } header: {
                    Text("Text Chat on This Mac")
                } footer: {
                    Text("Local agents use the account signed in to their CLI and can access your library through Chippy tools.")
                }
                .task { await setup.refresh() }
                #endif
                Section {
                    if let models = cloud.models {
                        modelRow(nil, title: String(localized: "Automatic"))
                        if let selectedID = cloud.selectedID, !models.contains(where: { $0.id == selectedID }) {
                            Label("\(selectedID) · Unavailable", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(models) { model in modelRow(model.id, title: model.alias) }
                        if models.isEmpty { Text("Flowcy has no enabled chat models.").foregroundStyle(.secondary) }
                    } else if cloud.isLoading {
                        ProgressView("Loading models…")
                    } else {
                        Button("Reload Models") { Task { await load() } }
                    }
                } header: {
                    Text("Flowcy Cloud Model")
                } footer: {
                    Text("Applies to cloud text generation in your account. Automatic uses the default for each task.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("AI Models")
            .summaryInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .disabled(cloud.isSaving)
            .overlay { if cloud.isSaving { ActionStatusOverlay(String(localized: "Saving model…")) } }
        }
        .summarySheetSize()
        .interactiveDismissDisabled(cloud.isSaving)
        .sensoryFeedback(.selection, trigger: feedback)
        .statusAlert("AI Models", message: failure) { failure = nil }
        #if os(macOS)
        .statusAlert("Local Agents", message: setup.errorMessage) { setup.errorMessage = nil }
        #endif
        .task { await load() }
    }

    private func modelRow(_ id: String?, title: String) -> some View {
        Button {
            guard id != cloud.selectedID else { return }
            Task {
                do {
                    try await cloud.select(id)
                    feedback += 1
                } catch { failure = error.localizedDescription }
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if id == cloud.selectedID { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(id == cloud.selectedID ? .isSelected : [])
        .accessibilityIdentifier("flowcy-model-\(id ?? "automatic")")
    }

    private func load() async {
        do {
            try await cloud.load()
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
