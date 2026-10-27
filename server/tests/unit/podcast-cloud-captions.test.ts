import { expect, it } from "vitest";
import { cloudCaptionsSrt, pageCloudCaptions } from "@/lib/podcast-video/captions";

it("pages the long mixed Chinese caption without losing text or timing", () => {
  const text = "再看 Anthropic 其上市招股文件中约九十页的风险因素写明 若缺乏适当保障 监督与安全措施 先进 AI 可能对人类构成灾难性或存在性风险";
  const pages = pageCloudCaptions([{ text, startSeconds: 4, endSeconds: 18 }]);
  expect(pages.length).toBeGreaterThan(1);
  expect(pages.map(p => p.text).join("").replace(/\s/g, "")).toBe(text.replace(/\s/g, ""));
  expect(pages[0].startSeconds).toBe(4);
  expect(pages.at(-1)?.endSeconds).toBe(18);
  for (const [index, page] of pages.entries()) {
    expect(page.text.split("\n").length).toBeLessThanOrEqual(2);
    for (const line of page.text.split("\n")) expect(Array.from(line).length).toBeLessThanOrEqual(18);
    expect(page.endSeconds).toBeGreaterThan(page.startSeconds);
    if (index) expect(page.startSeconds).toBe(pages[index - 1].endSeconds);
  }
});

it("keeps English words intact and retains gaps and explicit SRT line breaks", () => {
  const text = "Cloud rendering captions should advance in smaller readable chunks while preserving the original narration timing for every story";
  const cues = [{ text, startSeconds: 1, endSeconds: 10 }, { text: "Version 2.0.1", startSeconds: 12, endSeconds: 13 }];
  const pages = pageCloudCaptions(cues);
  expect(pages.length).toBeGreaterThan(2);
  expect(pages.slice(0, -1).map(p => p.text).join(" ").replace(/\s+/g, " ")).toBe(text);
  expect(pages.at(-2)?.endSeconds).toBe(10);
  expect(pages.at(-1)).toEqual({ ...cues[1], paged: true });
  expect(cloudCaptionsSrt(cues)).toContain("00:00:12,000 --> 00:00:13,000\nVersion 2.0.1\n");
  expect(cloudCaptionsSrt(cues)).toContain(pages[0].text);
});

it("omits empty or invalid cues and keeps long unbroken words intact", () => {
  expect(pageCloudCaptions([{ text: " ", startSeconds: 0, endSeconds: 1 },
    { text: "bad", startSeconds: NaN, endSeconds: 2 }])).toEqual([]);
  const pages = pageCloudCaptions([{ text: "a".repeat(150), startSeconds: 0, endSeconds: 10 }]);
  expect(pages.map(p => p.text.replace(/\n/g, "")).join("")).toBe("a".repeat(150));
  expect(pages).toHaveLength(1);
});
