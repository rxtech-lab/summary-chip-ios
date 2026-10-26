import { describe, expect, it } from "vitest";
import { alignPodcastCaptions, captionText } from "@/lib/services/podcast-captions";

describe("transcribed podcast captions", () => {
  it("corrects recognized names with the original script and retains unequal timing and gaps", () => {
    expect(alignPodcastCaptions("Welcome to RxLab! Here's the news.", [
      { text: "Welcome to Rexlab", startSecond: 0.3, endSecond: 4.8 },
      { text: "Here's the news", startSecond: 5.7, endSecond: 6.5 },
    ])).toEqual([
      { text: "Welcome to RxLab", startSeconds: 0.3, endSeconds: 4.8 },
      { text: "Heres the news", startSeconds: 5.7, endSeconds: 6.5 },
    ]);
  });
  it("supports Chinese and strips all punctuation", () => {
    expect(alignPodcastCaptions("大家好，今天有新闻！", [
      { text: "大家好", startSecond: 1, endSecond: 2 },
      { text: "今天有新闻", startSecond: 3, endSecond: 6 },
    ]).map(c => c.text)).toEqual(["大家好", "今天有新闻"]);
    expect(captionText("Here's ‘AI’—e-mail，新闻！")).toBe("Heres AI e mail 新闻");
  });
  it("matches Simplified recognition to Traditional captions without changing text or timing", () => {
    expect(alignPodcastCaptions("軟體開發與資料處理。學習語言與閱讀新聞。", [
      { text: "软体开发与资料处理", startSecond: 0.2, endSecond: 3.7 },
      { text: "学习语言与阅读新闻", startSecond: 4.5, endSecond: 8.1 },
    ])).toEqual([
      { text: "軟體開發與資料處理", startSeconds: 0.2, endSeconds: 3.7 },
      { text: "學習語言與閱讀新聞", startSeconds: 4.5, endSeconds: 8.1 },
    ]);
  });
  it("aligns Chinese even when recognition divides words differently across segments", () => {
    expect(alignPodcastCaptions("模型處理模糊情境", [
      { text: "模型处", startSecond: 0, endSecond: 1 },
      { text: "理模糊情境", startSecond: 1.5, endSecond: 3 },
    ])).toEqual([
      { text: "模型處", startSeconds: 0, endSeconds: 1 },
      { text: "理模糊情境", startSeconds: 1.5, endSeconds: 3 },
    ]);
  });
  it("still rejects unrelated Chinese recognition", () => {
    expect(() => alignPodcastCaptions("軟體開發與資料處理", [
      { text: "今天晴天我要吃苹果", startSecond: 0, endSecond: 3 },
    ])).toThrow("Transcript does not match podcast script");
  });
  it("restores omitted words and removes hallucinated text", () => {
    const cues = alignPodcastCaptions("This is the original script. Next story.", [
      { text: "This is original script", startSecond: 0, endSecond: 2 },
      { text: "Next story thanks", startSecond: 3, endSecond: 4 },
    ]);
    expect(cues.map(c => c.text).join(" ")).toBe("This is the original script Next story");
  });
  it("rejects missing, overlapping, nonfinite and unrelated transcripts", () => {
    for (const segments of [[], [{ text: "Hello", startSecond: NaN, endSecond: 1 }],
      [{ text: "Hello", startSecond: 2, endSecond: 1 }],
      [{ text: "Hello", startSecond: 0, endSecond: 2 }, { text: "world", startSecond: 1, endSecond: 3 }],
      [{ text: "Completely unrelated words", startSecond: 0, endSecond: 1 }]]) {
      expect(() => alignPodcastCaptions("Hello world", segments)).toThrow();
    }
  });
});
