import Foundation
import Testing
@testable import SummaryKit

struct PodcastPlanTests {
    private func plan() throws -> PodcastPlan {
        let json = #"{"id":"draft","revision":0,"confirmed":false,"script":{"title":"Daily news","summary":"A battery breakthrough.","mood":"focused","speakers":[{"name":"Alex","voice":"voice"}],"segments":[{"speaker":0,"chipId":"chip","caption":"A new battery was announced.","camera":"Slow zoom into a battery diagram."}]}}"#
        return try JSONDecoder().decode(PodcastPlan.self, from: Data(json.utf8))
    }

    @Test func validatesReviewedTextBeforeConfirmation() throws {
        var draft = try plan()
        #expect(draft.isValid)
        draft.script.segments[0].camera = " \n "
        #expect(!draft.isValid)
        draft = try plan()
        draft.script.segments[0].caption = String(repeating: "😀", count: 251)
        #expect(!draft.isValid)
        draft.script.segments[0].caption = String(repeating: "😀", count: 250)
        #expect(draft.isValid)
        draft.script.segments[0].speaker = 1
        #expect(!draft.isValid)
    }

    @Test func decodesChatAndAlignsStoryboardFrames() throws {
        let json = #"{"id":"draft","revision":2,"confirmed":false,"storyboard":true,"messages":[{"id":"m1","role":"user","text":"Shorter","revision":1,"createdAt":"2030-01-01T00:00:00Z"},{"id":"m2","role":"assistant","text":"Done.","revision":2,"createdAt":"2030-01-01T00:00:00Z"}],"frames":["https://example.com/a.png",null],"script":{"title":"Daily news","mood":"focused","speakers":[{"name":"Alex","voice":"voice"}],"segments":[{"speaker":0,"chipId":"chip","caption":"One.","camera":"Wide."},{"speaker":0,"chipId":"chip","caption":"Two.","camera":"Close."}]}}"#
        let decoded = try JSONDecoder().decode(PodcastPlan.self, from: Data(json.utf8))
        #expect(decoded.messages.map(\.role) == [.user, .assistant])
        #expect(decoded.frame(at: 0)?.absoluteString == "https://example.com/a.png")
        #expect(decoded.frame(at: 1) == nil)
        #expect(decoded.frame(at: 5) == nil)
        #expect(decoded.missingFrameCount == 1)
        #expect(decoded.speakerName(for: decoded.script.segments[0]) == "Alex")
        // Older servers send neither field.
        let legacy = try plan()
        #expect(legacy.messages.isEmpty && legacy.frames.isEmpty && legacy.missingFrameCount == 0)
    }

    @Test func summaryMustStayBelowTwoHundredWords() throws {
        var draft = try plan()
        draft.script.summary = String(repeating: "word ", count: 199)
        #expect(draft.isValid)
        draft.script.summary = String(repeating: "word ", count: 200)
        #expect(!draft.isValid)
        draft.script.summary = " "
        #expect(!draft.isValid)
        draft.script.summary = String(repeating: "a", count: 1201)
        #expect(!draft.isValid)
        draft.script.summary = nil
        #expect(draft.isValid)
    }
}
