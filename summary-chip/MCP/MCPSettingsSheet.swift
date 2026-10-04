#if os(macOS)
import AppKit
import SummaryKit
import SwiftUI

/// Turns the MCP server on or off, sets its port and shows how to connect an agent to it.
struct MCPSettingsSheet: View {
    let controller: MCPServerController
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""
    @State private var client: MCPClientKind = .claudeCode
    @State private var revealsToken = false
    @State private var confirmsRegenerate = false
    @State private var copiedMessage: String?
    @State private var copyCount = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                if controller.isEnabled {
                    connectionSection
                    clientSection
                }
                toolsSection
            }
            .formStyle(.grouped)
            .navigationTitle("MCP Server")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("mcp-done")
                }
            }
            .overlay {
                if controller.isBusy {
                    ActionStatusOverlay("Starting MCP server…")
                } else if let copiedMessage {
                    ActionStatusOverlay(copiedMessage, isWorking: false)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: copiedMessage)
            .sensoryFeedback(.success, trigger: copyCount)
            .sensoryFeedback(.error, trigger: errorMessage)
            .statusAlert("MCP Server", message: errorMessage) { errorMessage = nil }
            .confirmationDialog("Regenerate the access token?", isPresented: $confirmsRegenerate, titleVisibility: .visible) {
                Button("Regenerate", role: .destructive) {
                    Task {
                        await controller.regenerateToken()
                        reportFailure()
                    }
                }
            } message: {
                Text("Agents set up with the current token stop working until you update their configuration.")
            }
            .task(id: copiedMessage) {
                guard copiedMessage != nil else { return }
                do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
                copiedMessage = nil
            }
            .onAppear { portText = String(controller.port) }
        }
        .frame(width: 560, height: 640)
    }

    // MARK: Sections

    private var serverSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { controller.isEnabled },
                set: { enabled in
                    Task {
                        await controller.setEnabled(enabled)
                        reportFailure()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable MCP Server")
                    Text("Lets AI agents on this Mac add, search and list your summaries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(controller.isBusy)
            .accessibilityIdentifier("mcp-enabled-toggle")

            LabeledContent("Status") {
                Label(statusTitle, systemImage: statusImage)
                    .foregroundStyle(statusColor)
            }
            .accessibilityIdentifier("mcp-status")

            LabeledContent("Port") {
                HStack {
                    TextField("Port", text: $portText, prompt: Text(String(MCPServerController.defaultPort)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit(applyPort)
                        .accessibilityIdentifier("mcp-port-field")
                    if Int(portText) != controller.port {
                        Button("Apply", action: applyPort)
                            .disabled(!isValidPort)
                            .accessibilityIdentifier("mcp-port-apply")
                    }
                }
            }
        } footer: {
            Text("The server runs while Chippy is open and only accepts connections from this Mac. Agents act as your signed-in account; added summaries count against your allowance.")
                .foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("URL") {
                HStack {
                    Text(controller.endpoint)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    copyButton(controller.endpoint, message: "URL copied", identifier: "mcp-copy-url")
                }
            }
            LabeledContent("Access Token") {
                HStack {
                    Text(revealsToken ? controller.token : String(repeating: "•", count: 16))
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(revealsToken ? "Hide" : "Show") { revealsToken.toggle() }
                        .accessibilityIdentifier("mcp-reveal-token")
                    copyButton(controller.token, message: "Token copied", identifier: "mcp-copy-token")
                }
            }
            Button("Regenerate Token…", role: .destructive) { confirmsRegenerate = true }
                .accessibilityIdentifier("mcp-regenerate-token")
        }
    }

    private var clientSection: some View {
        Section {
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
                Text(snippet)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") { copy(snippet, message: "Configuration copied") }
                        .accessibilityIdentifier("mcp-copy-config")
                }
            }
        } header: {
            Text("Connect an Agent")
        }
    }

    private var toolsSection: some View {
        Section("Tools") {
            ForEach(MCPToolSummary.all) { tool in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name).font(.body.monospaced())
                    Text(tool.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Helpers

    private var snippet: String { client.configuration(endpoint: controller.endpoint, token: controller.token) }

    private var isValidPort: Bool {
        Int(portText).map(MCPServerController.portRange.contains) ?? false
    }

    private func applyPort() {
        guard let port = Int(portText), MCPServerController.portRange.contains(port) else {
            errorMessage = "Enter a port between \(MCPServerController.portRange.lowerBound) and \(MCPServerController.portRange.upperBound)."
            return
        }
        Task {
            await controller.setPort(port)
            reportFailure()
        }
    }

    private func reportFailure() {
        if case .failed(let message) = controller.status { errorMessage = message }
    }

    private func copyButton(_ value: String, message: String, identifier: String) -> some View {
        Button("Copy", systemImage: "doc.on.doc") { copy(value, message: message) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityIdentifier(identifier)
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedMessage = message
        copyCount += 1
    }

    private var statusTitle: String {
        switch controller.status {
        case .stopped: "Off"
        case .starting: "Starting…"
        case .running(let port): "Running on port \(port)"
        case .failed: "Couldn’t start"
        }
    }

    private var statusImage: String {
        switch controller.status {
        case .stopped: "pause.circle"
        case .starting: "hourglass"
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .running: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

/// Agents the sheet has ready-made configuration for.
enum MCPClientKind: String, CaseIterable, Identifiable {
    case claudeCode, claudeDesktop, json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .json: "Cursor & Others"
        }
    }

    var instructions: String {
        switch self {
        case .claudeCode: "Run this in Terminal. Add --scope user to use Chippy in every project."
        case .claudeDesktop: "Add this to claude_desktop_config.json (Settings → Developer → Edit Config). Requires Node.js."
        case .json: "Add this to the agent’s MCP configuration, e.g. ~/.cursor/mcp.json or a project’s .mcp.json."
        }
    }

    func configuration(endpoint: String, token: String) -> String {
        switch self {
        case .claudeCode:
            return "claude mcp add --transport http chippy \(endpoint) --header \"Authorization: Bearer \(token)\""
        case .claudeDesktop:
            return """
            {
              "mcpServers": {
                "chippy": {
                  "command": "npx",
                  "args": ["-y", "mcp-remote", "\(endpoint)", "--header", "Authorization: Bearer \(token)"]
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
                  "headers": { "Authorization": "Bearer \(token)" }
                }
              }
            }
            """
        }
    }
}

private struct MCPToolSummary: Identifiable {
    let name: String
    let detail: String
    var id: String { name }

    static let all = [
        MCPToolSummary(name: ChippyMCPTools.Name.addSummary, detail: "Save a summary, its key points, tags and raw source text."),
        MCPToolSummary(name: ChippyMCPTools.Name.searchSummaries, detail: "Find summaries by meaning, optionally from one source."),
        MCPToolSummary(name: ChippyMCPTools.Name.listSummaries, detail: "List summaries newest first by source, category, tag or visibility."),
    ]
}
#endif
