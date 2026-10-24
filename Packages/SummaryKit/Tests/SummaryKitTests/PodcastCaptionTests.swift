import Testing
@testable import SummaryKit

@Suite struct PodcastCaptionTests {
    @Test func showsTwoPhrasesAtATimeWithoutDroppingWords() {
        let text = "Welcome to the daily podcast. Here's our first story, followed by a useful takeaway."
        let timeline = PodcastCaptionTimeline(text)
        #expect(timeline.phrases.count >= 3)
        #expect(timeline.phrases.joined(separator: " ") == text)
        #expect(timeline.lines(at: 0) == ["Welcome to the daily podcast", "Here's our first story"])
        #expect(timeline.caption(at: 0) == "Welcome to the daily podcast\nHere's our first story")
        #expect(timeline.lines(at: 1).last == "followed by a useful takeaway")
        #expect(timeline.lines(at: -1) == timeline.lines(at: 0))
        #expect(timeline.lines(at: .nan) == timeline.lines(at: 0))
    }

    @Test func replacesPunctuationWithSpaces() {
        #expect(PodcastCaptionTimeline.withoutPunctuation("大家好，今天「AI」新闻。") == "大家好 今天 AI 新闻")
        #expect(PodcastCaptionTimeline.withoutPunctuation("Wait... what's e-mail?!") == "Wait what's e-mail")
        let chinese = PodcastCaptionTimeline("大家好，欢迎收听。今天有三条新闻！")
        #expect(chinese.lines(at: 0) == ["大家好", "欢迎收听"])
        #expect(chinese.lines(at: 1) == ["今天有三条新闻"])
    }

    @Test func boundsUnpunctuatedTextAndPreservesUnicode() {
        let text = String(repeating: "字幕要保持简短🗼", count: 20)
        let timeline = PodcastCaptionTimeline(text)
        #expect(timeline.phrases.allSatisfy { $0.count <= 18 })
        #expect(timeline.phrases.joined() == text)
        #expect(PodcastCaptionTimeline("").caption(at: 0.5).isEmpty)
        let english = PodcastCaptionTimeline(String(repeating: "A useful word ", count: 30))
        #expect(english.phrases.allSatisfy { $0.count <= 36 })
        #expect(english.lines(at: 0.5).count == 2)
    }

    @Test func followsTheVoiceAndSnapsSentenceEndsToMeasuredPauses() {
        let timeline = PodcastCaptionTimeline("Short one. Then a much longer second sentence follows here. End.")
        #expect(timeline.phrases == ["Short one.", "Then a much longer second sentence", "follows here.", "End."])
        // The speaker lingers on the first sentence, then pauses at 3s and again at 8.6s.
        let timing = PodcastCaptionTimeline.Timing(start: 1, end: 10, pauses: [3, 8.6])
        let ends = timeline.phraseEnds(timing)
        #expect(ends[0] == 3)
        #expect(ends[2] == 8.6)
        #expect(ends[3] == 10)
        #expect(ends[1] > 3 && ends[1] < 8.6)
        // Before the voice starts the first page shows; after the long pause the next one does.
        #expect(timeline.lines(at: 0, timing: timing) == ["Short one", "Then a much longer second sentence"])
        #expect(timeline.lines(at: 9, timing: timing) == ["follows here", "End"])
        // Without measured pauses, timing falls back to speaking weight across the voiced span.
        let plain = timeline.phraseEnds(.init(start: 0, end: 10))
        #expect(plain == plain.sorted() && plain.last == 10)
        #expect(timeline.lines(at: .nan, timing: timing) == timeline.lines(at: 0, timing: timing))
    }

    @Test func ignoresPausesFarFromAnyPunctuation() {
        let timeline = PodcastCaptionTimeline("One two three four five. Six seven eight nine ten.")
        // A breath mid-sentence at 1s must not pull the first sentence end away from 5s.
        let ends = timeline.phraseEnds(.init(start: 0, end: 10, pauses: [1, 5]))
        #expect(ends[0] == 5)
    }
}
