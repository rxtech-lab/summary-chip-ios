import Foundation
import AgentMessageListUI
import Observation
import SummaryKit

nonisolated struct ChatToolActivity: Identifiable, Hashable, Sendable {
    let id: String
    let toolName: String
    var label: String
    var isRunning: Bool
    var references: [SummaryReference]
}

/// Row model for the RxAgentSDK `MessageList`.
nonisolated struct ChatEntry: Identifiable, Hashable, MessageListItem {
    enum Role: Hashable { case user, assistant }

    let id: String
    let role: Role
    var text: String
    var tools: [ChatToolActivity] = []
    var errorText: String?
    var isStreaming = false

    var isUserMessage: Bool { role == .user }
}

/// In-memory agent conversation against `POST /api/v1/chat`.
@Observable
final class ChatModel {
    private let client: ChatStreamClient
    /// Set when chatting from a summary's detail screen; the agent answers from its original text.
    let summaryID: String?
    private(set) var entries: [ChatEntry] = []
    private(set) var isStreaming = false
    var draft = ""
    private var task: Task<Void, Never>?

    init(client: ChatStreamClient, summaryID: String? = nil) {
        self.client = client
        self.summaryID = summaryID
    }

    var suggestions: [String] { summaryID == nil ? Self.librarySuggestions : Self.summarySuggestions }

    static let librarySuggestions = [
        "What did I save about AI this week?",
        "Summarise my technology summaries",
        "Find the PDF I shared about research",
        "Which shared links are about to expire?",
    ]

    static let summarySuggestions = [
        "Explain this in simpler terms",
        "What details did the summary leave out?",
        "What are the strongest arguments here?",
        "Find related summaries in my library",
    ]

    func send(_ text: String? = nil) {
        let content = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isStreaming else { return }
        draft = ""
        entries.append(ChatEntry(id: UUID().uuidString, role: .user, text: content))
        let request = Self.uiMessages(from: entries)
        let assistantID = UUID().uuidString
        entries.append(ChatEntry(id: assistantID, role: .assistant, text: "", isStreaming: true))
        isStreaming = true
        task = Task { await stream(request, into: assistantID) }
    }

    func stop() {
        task?.cancel()
        task = nil
        finish(nil)
    }

    func newChat() {
        stop()
        entries = []
        draft = ""
    }

    private func stream(_ messages: [ChatUIMessage], into id: String) async {
        do {
            for try await event in client.stream(messages: messages, summaryID: summaryID) {
                apply(event, to: id)
            }
            finish(id)
        } catch is CancellationError {
            finish(id)
        } catch let error as URLError where error.code == .cancelled {
            finish(id)
        } catch {
            update(id) { $0.errorText = error.localizedDescription }
            finish(id)
        }
    }

    private func apply(_ event: ChatStreamEvent, to id: String) {
        switch event {
        case .textStart, .textEnd, .done:
            break
        case .textDelta(_, let delta):
            update(id) { $0.text += delta }
        case .toolInputAvailable(let callID, let name, let input):
            update(id) { entry in
                entry.tools.append(ChatToolActivity(
                    id: callID,
                    toolName: name,
                    label: ChatToolOutput.activityLabel(toolName: name, input: input),
                    isRunning: true,
                    references: []
                ))
            }
        case .toolOutputAvailable(let callID, let output):
            update(id) { entry in
                if let index = entry.tools.firstIndex(where: { $0.id == callID }) {
                    entry.tools[index].isRunning = false
                    entry.tools[index].references = ChatToolOutput.references(from: output)
                } else {
                    entry.tools.append(ChatToolActivity(id: callID, toolName: "", label: "", isRunning: false, references: ChatToolOutput.references(from: output)))
                }
            }
        case .error(let message):
            update(id) { $0.errorText = message }
        case .finish:
            update(id) { entry in
                for index in entry.tools.indices { entry.tools[index].isRunning = false }
            }
        }
    }

    private func finish(_ id: String?) {
        isStreaming = false
        for index in entries.indices where entries[index].isStreaming {
            entries[index].isStreaming = false
            for tool in entries[index].tools.indices { entries[index].tools[tool].isRunning = false }
        }
    }

    private func update(_ id: String, _ change: (inout ChatEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    /// History as text-only UI messages. Tool results are folded into the assistant text so
    /// the agent keeps the context without iOS sending tool parts.
    static func uiMessages(from entries: [ChatEntry]) -> [ChatUIMessage] {
        entries.compactMap { entry in
            switch entry.role {
            case .user:
                return ChatUIMessage(id: entry.id, role: .user, text: entry.text)
            case .assistant:
                var text = entry.text
                let references = entry.tools.flatMap(\.references)
                if !references.isEmpty {
                    let list = references.prefix(10).map { ref in
                        "- \(ref.title) (id: \(ref.id)\(ref.shareUrl.map { ", \($0.absoluteString)" } ?? ""))"
                    }.joined(separator: "\n")
                    text += (text.isEmpty ? "" : "\n\n") + "[Summaries shown to the user]\n" + list
                }
                guard !text.isEmpty else { return nil }
                return ChatUIMessage(id: entry.id, role: .assistant, text: text)
            }
        }
    }
}
