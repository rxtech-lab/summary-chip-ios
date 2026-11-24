#if os(macOS)
import Foundation
import LocalAgentKit
import SummaryKit
import Testing
@testable import summary_chip

@MainActor
struct LocalChatTurnTests {
    private final class Driver: LocalAgentDriver {
        var onEvent: ((LocalAgentEvent) -> Void)?
        var sent: String?
        var stopped = false
        var events: [LocalAgentEvent] = []
        func start() async throws {}
        func send(_ text: String) { sent = text; for event in events { onEvent?(event) } }
        func interrupt() {}
        func stop() { stopped = true; onEvent = nil }
    }

    @Test func localTurnUpdatesTheTranscriptAndDocument() async throws {
        let driver = Driver()
        driver.events = [.textDelta("Updating"), .toolStarted(id: "a", name: "mcp__chippy_app__update_trip", input: Data("{}".utf8)),
                         .toolFinished(id: "a", output: #"{"version":2}"#, isError: false), .textDelta("Done"), .turnFinished]
        var transcript: [ChatStreamEvent] = []
        var changed = false
        try await LocalChatTurn.run(prompt: "Update the trip", driver: driver, receive: { transcript.append($0) }, documentChanged: { changed = true })
        #expect(driver.sent == "Update the trip")
        #expect(driver.stopped && changed)
        #expect(transcript == [.textDelta(id: "local", delta: "Updating"), .toolInputAvailable(toolCallId: "a", toolName: "updateTrip", input: .object([:])),
                               .toolOutputAvailable(toolCallId: "a", output: .object(["version": .number(2)])), .textDelta(id: "local", delta: "Done"), .finish])
    }

    @Test func cancellingAWaitingTurnTerminatesTheRunner() async {
        let driver = Driver()
        let turn = Task { try await LocalChatTurn.run(prompt: "Wait", driver: driver, receive: { _ in }, documentChanged: {}) }
        while driver.sent == nil { await Task.yield() }
        turn.cancel()
        await #expect(throws: CancellationError.self) { try await turn.value }
        #expect(driver.stopped)
    }

    @Test func localAgentsRememberSeparateModels() throws {
        let suite = "chat-agent-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ChatAgentSelection(defaults: defaults).localAgent == nil)
        for agent in LocalAgentKind.allCases {
            defaults.set(agent.rawValue, forKey: ChatAgentSelection.providerKey)
            defaults.set("model-\(agent.rawValue)", forKey: ChatAgentSelection.modelKey(for: agent))
            let selection = ChatAgentSelection(defaults: defaults)
            #expect(selection.localAgent == agent)
            #expect(selection.localModelID == "model-\(agent.rawValue)")
        }
    }
}
#endif
