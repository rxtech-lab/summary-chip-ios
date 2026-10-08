import SummaryKit
import SwiftUI

/// The hosted MCP server: its URL, the account's API keys with their usage, and the tools agents get.
/// Creating and renaming a key happen in their own sheets; revoking asks for confirmation.
struct MCPSettingsSheet: View {
    let api: SummaryAPIClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var keys: [APIKey]?
    @State private var loadError: String?
    @State private var tools: [MCPTool]?
    @State private var toolsLoadError: String?
    @State private var selectedTool: MCPTool?
    @State private var interactionCount = 0
    @State private var showsCreate = false
    @State private var renaming: APIKey?
    @State private var revoking: APIKey?
    @State private var busyMessage: String?
    @State private var toast: String?
    @State private var successCount = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                endpointSection
                keysSection
                toolsSection
            }
            .formStyle(.grouped)
            .navigationTitle("MCP Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("mcp-done")
                }
                #if os(iOS)
                // macOS sheets don't show primary-action items, so the keys section also has a button.
                ToolbarItem(placement: .primaryAction) {
                    Button("New API Key", systemImage: "plus") { showsCreate = true }
                        .accessibilityIdentifier("mcp-new-key")
                }
                #endif
            }
            .refreshable { await load() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await load()
            }
            .sheet(item: $selectedTool, onDismiss: { interactionCount += 1 }) { tool in
                MCPToolDetailsSheet(tool: tool)
            }
            .sheet(isPresented: $showsCreate) {
                CreateAPIKeySheet(api: api) { created in
                    keys = [created] + (keys ?? [])
                }
            }
            .sheet(item: $renaming) { key in
                RenameAPIKeySheet(api: api, key: key) { renamed in
                    keys = keys?.map { $0.id == renamed.id ? renamed : $0 }
                }
            }
            .confirmationDialog(
                revoking.map { String(localized: "Revoke “\($0.name)”?") } ?? "",
                isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                titleVisibility: .visible,
                presenting: revoking
            ) { key in
                Button("Revoke Key", role: .destructive) { revoke(key) }
            } message: { _ in
                Text("Agents using this key stop working immediately. This can’t be undone.")
            }
            .overlay {
                if let busyMessage {
                    ActionStatusOverlay(busyMessage)
                } else if let toast {
                    ActionStatusOverlay(toast, isWorking: false)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: toast)
            .sensoryFeedback(.success, trigger: successCount)
            .sensoryFeedback(.selection, trigger: interactionCount)
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
            .sensoryFeedback(.error, trigger: toolsLoadError) { _, new in new != nil }
            .statusAlert("MCP Server", message: errorMessage) { errorMessage = nil }
            .task(id: toast) {
                guard toast != nil else { return }
                do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
                toast = nil
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 620)
        #endif
    }

    // MARK: Sections

    private var endpointSection: some View {
        Section {
            LabeledContent("URL") {
                HStack {
                    Text(api.mcpEndpoint.absoluteString)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") {
                        MCPPasteboard.copy(api.mcpEndpoint.absoluteString)
                        toast = String(localized: "URL copied")
                        successCount += 1
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("mcp-copy-url")
                }
            }
        } footer: {
            Text("AI agents such as Claude connect to this URL with an API key to add, search and list your summaries and trips. They act as your account, from any device. Summaries and trips they add are free and don't use your allowance or points.")
        }
    }

    @ViewBuilder
    private var keysSection: some View {
        Section {
            if let keys {
                if keys.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No API keys yet")
                            .font(.headline)
                        Text("Create a key for each agent you connect, so you can see its usage and revoke it on its own.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Create API Key…") { showsCreate = true }
                            .accessibilityIdentifier("mcp-create-first-key")
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(keys) { key in
                        APIKeyRow(key: key, onRename: { renaming = key }, onRevoke: { revoking = key })
                    }
                    Button("New API Key…", systemImage: "plus") { showsCreate = true }
                        .accessibilityIdentifier("mcp-add-key")
                }
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        } header: {
            Text("API Keys")
        } footer: {
            if let keys, !keys.isEmpty {
                Text("Only a hash of each key is stored, so a key can’t be shown again. Revoke a key you lost and create a new one.")
            }
        }
    }

    private var toolsSection: some View {
        Section("Tools") {
            if let tools {
                if tools.isEmpty {
                    Text("No tools available")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tools) { tool in
                        Button {
                            interactionCount += 1
                            selectedTool = tool
                        } label: {
                            HStack {
                                Text(verbatim: tool.name).font(.body.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mcp-tool-\(tool.name)")
                    }
                }
            } else if let toolsLoadError {
                Text(toolsLoadError)
                    .foregroundStyle(.secondary)
                Button("Try Again", systemImage: "arrow.clockwise") {
                    interactionCount += 1
                    Task { await loadTools() }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        async let keysLoad: Void = loadKeys()
        async let toolsLoad: Void = loadTools()
        _ = await (keysLoad, toolsLoad)
    }

    private func loadKeys() async {
        do {
            keys = try await api.apiKeys()
            loadError = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            if keys == nil { loadError = error.localizedDescription } else { errorMessage = error.localizedDescription }
        }
    }

    private func loadTools() async {
        toolsLoadError = nil
        do {
            tools = try await api.mcpTools()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            if tools == nil { toolsLoadError = error.localizedDescription } else { errorMessage = error.localizedDescription }
        }
    }

    private func revoke(_ key: APIKey) {
        busyMessage = String(localized: "Revoking key…")
        Task {
            defer { busyMessage = nil }
            do {
                try await api.revokeAPIKey(id: key.id)
                keys?.removeAll { $0.id == key.id }
                toast = String(localized: "Key revoked")
                successCount += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One key: its name, hint and usage, with rename and revoke actions.
private struct APIKeyRow: View {
    let key: APIKey
    let onRename: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(key.name)
                    .font(.headline)
                Text(verbatim: key.hint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(key.toolCallCount) tool calls", systemImage: "wrench.and.screwdriver")
                    Label("\(key.summariesAddedCount) summaries added", systemImage: "plus.square.on.square")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(lastUsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            #if os(macOS)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Actions for \(key.name)"))
            .accessibilityIdentifier("mcp-key-actions")
            #endif
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .contextMenu { actions }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button("Revoke", systemImage: "trash", role: .destructive, action: onRevoke)
            Button("Rename", systemImage: "pencil", action: onRename)
                .tint(.indigo)
        }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mcp-key-row")
    }

    @ViewBuilder
    private var actions: some View {
        Button("Rename…", systemImage: "pencil", action: onRename)
        Button("Revoke…", systemImage: "trash", role: .destructive, action: onRevoke)
    }

    private var lastUsed: String {
        let created = String(localized: "Created \(key.createdAt.formatted(date: .abbreviated, time: .omitted))")
        guard let lastUsedAt = key.lastUsedAt else { return String(localized: "\(created) · Never used") }
        return String(localized: "\(created) · Last used \(lastUsedAt.formatted(.relative(presentation: .named)))")
    }
}

private struct MCPToolDetailsSheet: View {
    let tool: MCPTool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: tool.name)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                if let description = tool.description {
                    Section("Description") {
                        Text(verbatim: description)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tool.title ?? tool.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 420)
        #endif
    }
}
