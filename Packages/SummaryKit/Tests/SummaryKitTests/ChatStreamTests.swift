import Foundation
import Testing
@testable import SummaryKit

@Suite struct ChatStreamTests {
    let parser = ChatStreamParser()

    @Test func parsesFixtureStream() throws {
        let text = String(decoding: try fixture("chat-stream.txt"), as: UTF8.self)
        let events = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { parser.parse(line: String($0)) }
        #expect(events.count == 8)
        guard case .toolInputAvailable(let callID, let tool, let input) = events[0] else {
            Issue.record("expected tool input, got \(events[0])"); return
        }
        #expect(callID == "call_1")
        #expect(tool == "searchSummaries")
        #expect(input["query"]?.stringValue == "apple chips")
        #expect(ChatToolOutput.activityLabel(toolName: tool, input: input) == "Searching for “apple chips”…")

        guard case .toolOutputAvailable(_, let output) = events[1] else { Issue.record("expected output"); return }
        let refs = ChatToolOutput.references(from: output)
        #expect(refs.count == 1)
        #expect(refs.first?.slug == "a1B2c3D4e5")
        #expect(refs.first?.createdAt != nil)

        #expect(events[2] == .textStart(id: "t1"))
        #expect(events[3] == .textDelta(id: "t1", delta: "Here is "))
        #expect(events[4] == .textDelta(id: "t1", delta: "**one** result."))
        #expect(events[5] == .textEnd(id: "t1"))
        #expect(events[6] == .finish)
        #expect(events[7] == .done)
    }

    @Test func handlesErrorsAndOddLines() {
        #expect(parser.parse(line: #"data: {"type":"error","errorText":"boom"}"#) == .error("boom"))
        #expect(parser.parse(line: #"data:{"type":"finish"}"#) == .finish)
        #expect(parser.parse(line: "data: [DONE]\r") == .done)
        #expect(parser.parse(line: ": keep-alive") == nil)
        #expect(parser.parse(line: "event: message") == nil)
        #expect(parser.parse(line: "data: not json") == nil)
        #expect(parser.parse(line: #"data: {"type":"reasoning-delta","delta":"x"}"#) == nil)
    }

    @Test func getSummaryOutputBecomesCard() throws {
        let output = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"summary":{"id":"x","slug":"s","title":"T","summary":"S","contentExcerpt":"…","tags":["a"]}}"#.utf8))
        #expect(ChatToolOutput.references(from: output).map(\.id) == ["x"])
        #expect(ChatToolOutput.references(from: .string("nope")).isEmpty)
    }

    @Test func describesToolCallsForCards() throws {
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"query":" sleep better ","category":"Health","tag":"habits","scope":"all"}"#.utf8))
        #expect(ChatToolOutput.detail(toolName: "searchSummaries", input: input) == "“sleep better” · Health · #habits")
        #expect(ChatToolOutput.detail(toolName: "searchSummaries", input: .object(["query": .string("")])) == nil)
        #expect(ChatToolOutput.detail(toolName: "getSummary", input: .object(["id": .string("x")])) == nil)

        let semantic = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"query":"sleep","semantic":true,"results":[]}"#.utf8))
        #expect(ChatToolOutput.isSemantic(semantic))
        #expect(!ChatToolOutput.isSemantic(.object(["results": .array([])])))
        #expect(ChatToolOutput.errorText(from: .object(["error": .string("Summary not found or not accessible.")])) == "Summary not found or not accessible.")
        #expect(ChatToolOutput.errorText(from: semantic) == nil)
    }

    @Test func encodesUIMessages() throws {
        let body = ChatRequestBody(messages: [ChatUIMessage(id: "1", role: .user, text: "hi")])
        let json = String(decoding: try SummaryJSON.encoder().encode(body), as: UTF8.self)
        #expect(json == #"{"messages":[{"id":"1","parts":[{"text":"hi","type":"text"}],"role":"user"}]}"#)
    }

    @Test func encodesFocusedSummaryID() throws {
        let body = ChatRequestBody(messages: [ChatUIMessage(id: "1", role: .user, text: "hi")], summaryId: "sum_1")
        let json = String(decoding: try SummaryJSON.encoder().encode(body), as: UTF8.self)
        #expect(json == #"{"messages":[{"id":"1","parts":[{"text":"hi","type":"text"}],"role":"user"}],"summaryId":"sum_1"}"#)
    }
}
