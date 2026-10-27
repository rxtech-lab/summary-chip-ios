import { expect, it, vi } from "vitest";
import { splitPodcastCaptions, decideCaptionBoundary } from "@/lib/ai/podcast-caption-splitting";
import { cloudCaptionsSrt, pageCloudCaptions } from "@/lib/podcast-video/captions";

const evaluate = vi.hoisted(() => vi.fn());
vi.mock("ai", () => ({ experimental_evaluate: evaluate }));
vi.mock("@/lib/ai/models", () => ({ evaluationModelId: () => "decision/test", evaluationModel: () => "model" }));

it("asks the configured decision model to choose only an existing split", async () => {
  evaluate.mockResolvedValue({ answers: { boundary: { choice: "1" } } });
  expect(await decideCaptionBoundary("今天关注网络安全与人工智能", [4, 8], new AbortController().signal)).toBe(8);
  expect(evaluate.mock.calls[0][0]).toMatchObject({ model: "model", maxRetries: 0,
    questions: { boundary: { type: "choice", criteria: { "1": JSON.stringify(["今天关注网络安全", "与人工智能"]) } } } });
});

it("preserves Chinese words, content, gaps, and decisions across exports", async () => {
  const text = "加拿大网络安全中心表示 已有攻击者在利用这个漏洞 但是仍需注意网络安全";
  const decide = vi.fn(async (_text: string, boundaries: number[]) => boundaries.at(-1)!);
  const cues = [{ text, startSeconds: 2, endSeconds: 12 }, { text: "下一条新闻", startSeconds: 14, endSeconds: 16 }];
  const pages = await splitPodcastCaptions(cues, undefined, decide);
  expect(decide).toHaveBeenCalled();
  expect(pages.every(page => page.paged)).toBe(true);
  expect(pages.map(page => page.text).join("").replace(/\s/g, "")).toBe((text + "下一条新闻").replace(/\s/g, ""));
  expect(pages.flatMap(page => page.text.split("\n")).filter(line => line.includes("网络安全"))).toHaveLength(2);
  expect(pages[0].startSeconds).toBe(2);
  expect(pages.at(-2)?.endSeconds).toBe(12);
  expect(pages.at(-1)?.startSeconds).toBe(14);
  expect(pageCloudCaptions(pages)).toEqual(pages);
  expect(cloudCaptionsSrt(pages)).toContain(pages[0].text);
  decide.mockClear();
  expect(await splitPodcastCaptions(pages, undefined, decide)).toEqual(pages);
  expect(decide).not.toHaveBeenCalled();
});

it("falls back once on failure without dropping text or breaking a long word", async () => {
  const decide = vi.fn(async () => { throw new Error("unavailable"); });
  const text = "These captions should use natural boundaries even when the decision service is unavailable for a longer narration";
  const pages = await splitPodcastCaptions([{ text, startSeconds: 0, endSeconds: 10 }], undefined, decide);
  expect(decide).toHaveBeenCalledTimes(1);
  expect(pages.map(p => p.text).join(" ").replace(/\s+/g, " ")).toBe(text);
  const word = "a".repeat(100);
  expect((await splitPodcastCaptions([{ text: word, startSeconds: 0, endSeconds: 4 }], undefined, decide))[0].text).toBe(word);
});

it("rejects cancellation and ignores invalid model choices", async () => {
  const controller = new AbortController(); controller.abort();
  await expect(splitPodcastCaptions([], controller.signal)).resolves.toEqual([]);
  await expect(splitPodcastCaptions([{ text: "hello", startSeconds: 0, endSeconds: 1 }], controller.signal)).rejects.toThrow();
  const text = "A long caption containing enough words that it must be split into several short lines without losing any original words";
  const pages = await splitPodcastCaptions([{ text, startSeconds: 1, endSeconds: 10 }], undefined, async () => -1);
  expect(pages.map(p => p.text).join(" ").replace(/\s+/g, " ")).toBe(text);
});
