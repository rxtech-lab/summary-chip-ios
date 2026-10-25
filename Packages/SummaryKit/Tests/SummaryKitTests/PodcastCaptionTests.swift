import Testing
@testable import SummaryKit

@Suite struct PodcastCaptionTests {
    @Test func wrapsChineseAtWordBoundaries() {
        let text = "加拿大网络安全中心表示 已有攻击者在利用这个漏洞 但是仍需注意网络安全"
        let pages = PodcastCaptionTimeline.pagedCues([.init(text: text, startSeconds: 0, endSeconds: 12)])
        let lines = pages.flatMap { $0.text.components(separatedBy: "\n") }
        #expect(lines.contains { $0.contains("但是") })
        #expect(lines.contains { $0.contains("漏洞") })
        #expect(lines.joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
    }

    @Test func keepsLongAndMixedScriptWordsWhole() {
        let word = "supercalifragilisticexpialidociousExtraLong"
        for text in ["Start \(word) end", "今天介绍这个 \(word) 技术"] {
            let timeline = PodcastCaptionTimeline(text)
            #expect(timeline.phrases.contains { $0.contains(word) })
            #expect(timeline.phrases.joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
        }
    }

    @Test func showsTwoPhrasesAtATimeWithoutDroppingWords() {
        let text = "Welcome to the daily podcast. Here's our first story, followed by a useful takeaway."
        let timeline = PodcastCaptionTimeline(text)
        #expect(timeline.phrases.count >= 3)
        #expect(timeline.phrases.joined(separator: " ") == text)
        #expect(timeline.lines(at: 0) == ["Welcome to the daily podcast", "Heres our first story"])
        #expect(timeline.caption(at: 0) == "Welcome to the daily podcast\nHeres our first story")
        #expect(timeline.lines(at: 1).last == "followed by a useful takeaway")
        #expect(timeline.lines(at: -1) == timeline.lines(at: 0))
        #expect(timeline.lines(at: .nan) == timeline.lines(at: 0))
    }

    @Test func usesTranscribedBoundariesAndHidesSilence() {
        let cues = [PodcastCaptionTimeline.Cue(text: "Hello, world!", startSeconds: 2, endSeconds: 3),
                    .init(text: "Second phrase", startSeconds: 5, endSeconds: 8)]
        #expect(PodcastCaptionTimeline.lines(at: 1, cues: cues).isEmpty)
        #expect(PodcastCaptionTimeline.lines(at: 2, cues: cues).joined(separator: " ") == "Hello world")
        #expect(PodcastCaptionTimeline.lines(at: 3, cues: cues).isEmpty)
        #expect(PodcastCaptionTimeline.lines(at: 5, cues: cues) == ["Second phrase"])
        #expect(PodcastCaptionTimeline.lines(at: 8, cues: cues).isEmpty)
    }

    @Test func splitsLongTranscriptionsIntoTwoLinePagesWithoutLosingText() {
        for text in [
            "社区中有人呼吁发展更多本地和开源模型 相关的梗图也在网上传播 其中一张画面带有 GPU 与盘蛇 名为 Come and Take It",
            "A longer spoken passage should advance through several short caption pages while preserving every word and keeping the original transcription boundaries"
        ] {
            let cue = PodcastCaptionTimeline.Cue(text: text, startSeconds: 2, endSeconds: 14)
            let pages = PodcastCaptionTimeline.pagedCues([cue])
            #expect(pages.count > 1)
            #expect(pages.first?.startSeconds == 2)
            #expect(pages.last?.endSeconds == 14)
            #expect(pages.allSatisfy { $0.text.components(separatedBy: "\n").count <= 2 })
            let compact = { (value: String) in value.filter { !$0.isWhitespace } }
            #expect(compact(pages.map(\.text).joined()) == compact(text))
            for (index, page) in pages.enumerated() {
                #expect(page.endSeconds > page.startSeconds)
                if index > 0 { #expect(page.startSeconds == pages[index - 1].endSeconds) }
                #expect(PodcastCaptionTimeline.lines(at: page.startSeconds, cues: [cue]) == page.text.components(separatedBy: "\n"))
            }
            #expect(PodcastCaptionTimeline.lines(at: 14, cues: [cue]).isEmpty)
        }
    }

    @Test func replacesPunctuationWithSpaces() {
        #expect(PodcastCaptionTimeline.withoutPunctuation("大家好，今天「AI」新闻。") == "大家好 今天 AI 新闻")
        #expect(PodcastCaptionTimeline.withoutPunctuation("Wait... what's e-mail?!") == "Wait whats e mail")
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
