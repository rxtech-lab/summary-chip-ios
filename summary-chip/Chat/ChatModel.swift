import Foundation
import AgentMessageListUI
import Observation
import SummaryKit

/// One agent tool call, shown as a card in the transcript. The optional fields were added later;
/// transcripts saved before them still decode.
nonisolated struct ChatToolActivity: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let toolName: String
    var label: String
    var isRunning: Bool
    var references: [SummaryReference]
    /// What the call was made with, e.g. the search query and filters.
    var detail: String? = nil
    /// Set once the tool returned; `nil` when the call was cut off.
    var finished: Bool? = nil
    /// The search matched by meaning (vector search), not only keywords.
    var isSemantic: Bool? = nil
    var errorText: String? = nil
    /// Result line for the local-file tools, e.g. "3 matches".
    var status: String? = nil
}

/// Row model for the RxAgentSDK `MessageList`.
nonisolated struct ChatEntry: Identifiable, Hashable, Codable, MessageListItem {
    enum Role: String, Hashable, Codable { case user, assistant }

    let id: String
    let role: Role
    var text: String
    var tools: [ChatToolActivity] = []
    var errorText: String?
    var isStreaming = false

    var isUserMessage: Bool { role == .user }
}

/// Agent conversation against `POST /api/v1/chat`, saved to `ChatTranscriptStore` so it
/// survives relaunches until the user starts a new chat or signs out.
@Observable
final class ChatModel {
    private let client: ChatStreamClient
    private let store: ChatTranscriptStore
    private let storeKey: String
    /// Set when chatting from a summary's detail screen; the agent answers from its original text.
    let summaryID: String?
    private(set) var entries: [ChatEntry] = []
    private(set) var isStreaming = false
    /// The last turn was refused because the points balance is empty.
    var needsTopUp = false
    var draft = ""
    private var task: Task<Void, Never>?

    init(client: ChatStreamClient, store: ChatTranscriptStore, summaryID: String? = nil) {
        self.client = client
        self.store = store
        self.summaryID = summaryID
        storeKey = summaryID.map(ChatTranscriptStore.key(summaryID:)) ?? ChatTranscriptStore.libraryKey
        entries = Self.restored(store.load([ChatEntry].self, key: storeKey) ?? [])
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
        persist()
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
        store.remove(key: storeKey)
    }

    private func stream(_ messages: [ChatUIMessage], into id: String) async {
        do {
            let localContent = await Self.localContent(summaryID: summaryID)
            for try await event in client.stream(messages: messages, summaryID: summaryID, localContent: localContent) {
                apply(event, to: id)
            }
            finish(id)
        } catch is CancellationError {
            finish(id)
        } catch let error as URLError where error.code == .cancelled {
            finish(id)
        } catch {
            update(id) { $0.errorText = error.localizedDescription }
            needsTopUp = (error as? SummaryAPIError)?.needsTopUp == true
            finish(id)
        }
    }

    /// The summary's linked local file, read fresh for each question so edits are picked up.
    /// The server never stores it; without it, answers fall back to the summary itself.
    private static func localContent(summaryID: String?) async -> String? {
        guard let summaryID, LocalFileStore().link(summaryID: summaryID) != nil else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? LocalDocument.readLinked(summaryID: summaryID).text
        }.value
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
                    references: [],
                    detail: ChatToolOutput.detail(toolName: name, input: input)
                ))
            }
        case .toolOutputAvailable(let callID, let output):
            update(id) { entry in
                let index = entry.tools.firstIndex(where: { $0.id == callID }) ?? {
                    entry.tools.append(ChatToolActivity(id: callID, toolName: "", label: "", isRunning: false, references: []))
                    return entry.tools.count - 1
                }()
                entry.tools[index].isRunning = false
                entry.tools[index].finished = true
                entry.tools[index].references = ChatToolOutput.references(from: output)
                entry.tools[index].isSemantic = ChatToolOutput.isSemantic(output)
                entry.tools[index].errorText = ChatToolOutput.errorText(from: output)
                entry.tools[index].status = ChatToolOutput.localFileStatus(toolName: entry.tools[index].toolName, output: output)
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
        persist()
    }

    private func persist() {
        guard !entries.isEmpty else { return }
        store.save(entries, key: storeKey)
    }

    /// A transcript saved mid-stream (the app was killed) comes back settled: nothing is
    /// streaming any more, and an empty assistant reply is dropped.
    static func restored(_ saved: [ChatEntry]) -> [ChatEntry] {
        saved.compactMap { entry in
            var entry = entry
            let wasStreaming = entry.isStreaming
            entry.isStreaming = false
            for index in entry.tools.indices { entry.tools[index].isRunning = false }
            if wasStreaming, entry.role == .assistant, entry.text.isEmpty, entry.errorText == nil,
               entry.tools.allSatisfy({ $0.references.isEmpty }) {
                return nil
            }
            return entry
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
