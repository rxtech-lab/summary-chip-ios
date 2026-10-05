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
    var webReferences: [ChatWebReference]? = nil
    var renderedUI: ChatRenderedUI? = nil
    /// Readable values from the rendered view, included in subsequent turns.
    var renderedText: String? = nil
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

/// The trip a chat with the trip agent is about. One conversation per trip; `isExpense` only
/// steers the empty state and suggestions towards adding costs.
nonisolated struct TripChat: Hashable {
    let id: String
    let title: String
    var isExpense = false
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
    /// Set when chatting with the trip agent from a trip's screen; the agent can edit the trip.
    let trip: TripChat?
    /// Called after the trip agent saved an edit to `trip`.
    @ObservationIgnored var onTripUpdated: (() -> Void)?
    private(set) var entries: [ChatEntry] = []
    private(set) var isStreaming = false
    /// The last turn was refused because the points balance is empty.
    var needsTopUp = false
    var draft = ""
    private var task: Task<Void, Never>?

    init(client: ChatStreamClient, store: ChatTranscriptStore, summaryID: String? = nil, trip: TripChat? = nil) {
        self.client = client
        self.store = store
        self.summaryID = trip == nil ? summaryID : nil
        self.trip = trip
        storeKey = trip.map { ChatTranscriptStore.key(tripID: $0.id) }
            ?? summaryID.map(ChatTranscriptStore.key(summaryID:))
            ?? ChatTranscriptStore.libraryKey
        entries = Self.restored(store.load([ChatEntry].self, key: storeKey) ?? [])
    }

    var suggestions: [String] {
        if let trip { return trip.isExpense ? Self.expenseSuggestions : Self.tripSuggestions }
        return summaryID == nil ? Self.librarySuggestions : Self.summarySuggestions
    }

    static let librarySuggestions = [
        String(localized: "What did I save about AI this week?"),
        String(localized: "Summarise my technology summaries"),
        String(localized: "Find the PDF I shared about research"),
        String(localized: "Which shared links are about to expire?"),
    ]

    static let summarySuggestions = [
        String(localized: "Explain this in simpler terms"),
        String(localized: "What details did the summary leave out?"),
        String(localized: "What are the strongest arguments here?"),
        String(localized: "Find related summaries in my library"),
    ]

    static let tripSuggestions = [
        String(localized: "Summarise the trip day by day"),
        String(localized: "Which nights don't have a hotel yet?"),
        String(localized: "What should I book next?"),
        String(localized: "Build a table comparing a rail pass with paying each fare by IC card"),
        String(localized: "How much have I spent so far?"),
    ]

    static let expenseSuggestions = [
        String(localized: "How much have I spent so far?"),
        String(localized: "Which costs are still unpaid?"),
        String(localized: "Break down the costs by category"),
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-chat-stream") {
            await previewStream(into: id)
            return
        }
        #endif
        do {
            let localContent = await Self.localContent(summaryID: summaryID)
            for try await event in client.stream(messages: messages, summaryID: summaryID, localContent: localContent, tripID: trip?.id) {
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

    #if DEBUG
    /// Exercises the real row updates without an account, network, or persisted chat.
    private func previewStream(into id: String) async {
        let chunks = [
            "# Streaming layout check\n\n",
            "The first paragraph stays in place while the answer grows.\n\n",
            "```swift\n", "let count = 1\n", "let next = count + 1\n", "print(next)\n", "```\n\n",
            "| Item | Value |\n| --- | --- |\n", "| First | One |\n", "| Second | Two |\n",
        ]
        do {
            for chunk in chunks {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                apply(.textDelta(id: "preview", delta: chunk), to: id)
            }
            // Keep extending one paragraph beyond the viewport to check following
            // and the reader's ability to scroll back during an active stream.
            apply(.textDelta(id: "preview", delta: "\n\n"), to: id)
            for index in 0..<20 {
                // Gaps let XCUITest interact without waiting for the whole turn
                // to finish; each burst still goes through the text-delta path.
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                apply(.textDelta(id: "preview", delta: String(repeating: "More streamed text fills the answer. ", count: index == 0 ? 24 : 8)), to: id)
            }
        } catch {}
        finish(id)
    }
    #endif

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
                if entry.tools[index].toolName == "searchWeb" {
                    entry.tools[index].webReferences = ChatToolOutput.webReferences(from: output)
                }
                if entry.tools[index].toolName == "renderUI" {
                    entry.tools[index].renderedUI = ChatToolOutput.renderedUI(from: output)
                    entry.tools[index].renderedText = output["text"]?.stringValue
                }
                if entry.tools[index].toolName == "updateTrip", entry.tools[index].errorText != nil {
                    // Sent back to the agent to fix; the raw issues are for the model, not the reader.
                    entry.tools[index].errorText = String(localized: "Some edits didn't fit the trip, so the agent corrected them.")
                }
                if let update = ChatToolOutput.tripUpdate(from: output) {
                    entry.tools[index].detail = update.summary
                    entry.tools[index].status = update.applied == 1 ? String(localized: "1 change saved") : String(localized: "\(update.applied) changes saved")
                }
            }
            if ChatToolOutput.tripUpdate(from: output).map({ $0.applied > 0 }) == true {
                onTripUpdated?()
            }
        case .toolOutputError(let callID, let error):
            update(id) { entry in
                let index = entry.tools.firstIndex(where: { $0.id == callID }) ?? {
                    entry.tools.append(ChatToolActivity(id: callID, toolName: "", label: "", isRunning: false, references: []))
                    return entry.tools.count - 1
                }()
                entry.tools[index].isRunning = false
                entry.tools[index].finished = true
                entry.tools[index].errorText = error
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
               entry.tools.allSatisfy({ $0.references.isEmpty && ($0.webReferences ?? []).isEmpty && $0.renderedUI == nil }) {
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
                let sources = entry.tools.flatMap { $0.webReferences ?? [] }
                if !sources.isEmpty {
                    text += "\n\n[Web sources shown to the user]\n" + sources.prefix(10).map {
                        "- \($0.title): \($0.url.absoluteString)\($0.snippet.map { "\n  \($0.prefix(500))" } ?? "")"
                    }.joined(separator: "\n")
                }
                for tool in entry.tools {
                    if let ui = tool.renderedUI {
                        text += "\n\n[Native view shown to the user: \(ui.title)]\n" + (tool.renderedText ?? "")
                    }
                }
                guard !text.isEmpty else { return nil }
                return ChatUIMessage(id: entry.id, role: .assistant, text: text)
            }
        }
    }
}
