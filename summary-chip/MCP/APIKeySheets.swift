import SummaryKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Names a new API key, creates it, then shows it once with ready-made agent configuration.
struct CreateAPIKeySheet: View {
    let api: SummaryAPIClient
    let onCreate: (APIKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var created: CreatedAPIKey?
    @State private var isCreating = false
    @State private var client: MCPClientKind = .claudeCode
    @State private var copiedMessage: String?
    @State private var copyCount = 0
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    keySection(created.key)
                    clientSection(created.key)
                } else {
                    nameSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle(created == nil ? String(localized: "New API Key") : String(localized: "API Key Created"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create", action: create)
                            .disabled(trimmedName.isEmpty || isCreating)
                            .accessibilityIdentifier("mcp-create-key")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("mcp-created-done")
                    }
                }
            }
            .interactiveDismissDisabled(isCreating)
            .overlay {
                if isCreating {
                    ActionStatusOverlay(String(localized: "Creating key…"))
                } else if let copiedMessage {
                    ActionStatusOverlay(copiedMessage, isWorking: false)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: copiedMessage)
            .sensoryFeedback(.success, trigger: copyCount)
            .sensoryFeedback(.success, trigger: created)
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
            .statusAlert("New API Key", message: errorMessage) { errorMessage = nil }
            .task(id: copiedMessage) {
                guard copiedMessage != nil else { return }
                do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
                copiedMessage = nil
            }
            .onAppear { nameFocused = true }
        }
        #if os(macOS)
        .frame(width: 540, height: created == nil ? 240 : 600)
        #endif
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameSection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("e.g. Claude Code on my laptop"))
                .focused($nameFocused)
                .onSubmit(create)
                .onChange(of: name) { _, value in
                    if value.count > 60 { name = String(value.prefix(60)) }
                }
                .accessibilityIdentifier("mcp-key-name")
        } footer: {
            Text("Name the key after the agent or device that uses it. The key gives full access to your summaries and trips.")
        }
    }

    private func keySection(_ key: String) -> some View {
        Section {
            Text(verbatim: key)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("mcp-created-key")
            Button("Copy Key", systemImage: "doc.on.doc") { copy(key, message: String(localized: "Key copied")) }
                .accessibilityIdentifier("mcp-copy-key")
        } header: {
            Text("Your API Key")
        } footer: {
            Text("Copy the key now. For your security, Chippy can’t show it again.")
        }
    }

    private func clientSection(_ key: String) -> some View {
        let snippet = client.configuration(endpoint: api.mcpEndpoint.absoluteString, key: key)
        return Section("Connect an Agent") {
            Picker("Agent", selection: $client) {
                ForEach(MCPClientKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .accessibilityIdentifier("mcp-client-picker")
            VStack(alignment: .leading, spacing: 8) {
                Text(client.instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: snippet)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
            Button("Copy Configuration", systemImage: "doc.on.doc") { copy(snippet, message: String(localized: "Configuration copied")) }
                .accessibilityIdentifier("mcp-copy-config")
        }
    }

    private func create() {
        let name = trimmedName
        guard !name.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let result = try await api.createAPIKey(name: name)
                created = result
                onCreate(result.apiKey)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copy(_ value: String, message: String) {
        MCPPasteboard.copy(value)
        copiedMessage = message
        copyCount += 1
    }
}

/// Renames a key; agents using it are unaffected.
struct RenameAPIKeySheet: View {
    let api: SummaryAPIClient
    let key: APIKey
    let onRename: (APIKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedCount = 0
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .onSubmit(save)
                        .onChange(of: name) { _, value in
                            if value.count > 60 { name = String(value.prefix(60)) }
                        }
                        .accessibilityIdentifier("mcp-rename-field")
                } footer: {
                    Text(verbatim: key.hint)
                        .font(.caption.monospaced())
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Rename Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty || trimmedName == key.name || isSaving)
                        .accessibilityIdentifier("mcp-rename-save")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .overlay {
                if isSaving { ActionStatusOverlay(String(localized: "Saving…")) }
            }
            .sensoryFeedback(.success, trigger: savedCount)
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
            .statusAlert("Rename Key", message: errorMessage) { errorMessage = nil }
            .onAppear {
                name = key.name
                nameFocused = true
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 200)
        #endif
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        let name = trimmedName
        guard !name.isEmpty, name != key.name, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                onRename(try await api.renameAPIKey(id: key.id, name: name))
                savedCount += 1
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Agents the create sheet has ready-made configuration for.
enum MCPClientKind: String, CaseIterable, Identifiable {
    case claudeCode, claudeDesktop, json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .json: String(localized: "Cursor & Others")
        }
    }

    var instructions: String {
        switch self {
        case .claudeCode: String(localized: "Run this in Terminal. Add --scope user to use Chippy in every project.")
        case .claudeDesktop: String(localized: "Add this to claude_desktop_config.json (Settings → Developer → Edit Config). Requires Node.js.")
        case .json: String(localized: "Add this to the agent’s MCP configuration, e.g. ~/.cursor/mcp.json or a project’s .mcp.json.")
        }
    }

    func configuration(endpoint: String, key: String) -> String {
        switch self {
        case .claudeCode:
            return "claude mcp add --transport http chippy \(endpoint) --header \"Authorization: Bearer \(key)\""
        case .claudeDesktop:
            return """
            {
              "mcpServers": {
                "chippy": {
                  "command": "npx",
                  "args": ["-y", "mcp-remote", "\(endpoint)", "--header", "Authorization: Bearer \(key)"]
                }
              }
            }
            """
        case .json:
            return """
            {
              "mcpServers": {
                "chippy": {
                  "type": "http",
                  "url": "\(endpoint)",
                  "headers": { "Authorization": "Bearer \(key)" }
                }
              }
            }
            """
        }
    }
}

enum MCPPasteboard {
    static func copy(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
