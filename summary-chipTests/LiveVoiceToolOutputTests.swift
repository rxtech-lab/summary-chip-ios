import Foundation
import LocalAgentKit
import SummaryKit
import Testing

/// A local agent's tool results have to reach the same app paths the cloud agent's do.
struct LiveVoiceToolOutputTests {
    private func output(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: LocalToolOutput.chatOutput(toolName: "selectGraphElements", output: raw))
    }

    @Test func hostedSelectionIsAppliedByTheOpenGraph() throws {
        let value = try output(#"{"selection":{"mode":"isolate","nodeIds":["a"],"edgeIds":["e"],"query":"MATCH (n) RETURN n"}}"#)
        let selection = try #require(ChatToolOutput.graphSelection(from: value))
        #expect(selection?.mode == .isolate)
        #expect(selection?.nodeIds == ["a"])
        #expect(selection?.edgeIds == ["e"])
    }

    @Test func hostedClearShowsTheWholeGraphAgain() throws {
        let value = try output("Cleared the selection.\n{\"selection\":null}")
        let selection = try #require(ChatToolOutput.graphSelection(from: value))
        #expect(selection == nil)
    }
}
