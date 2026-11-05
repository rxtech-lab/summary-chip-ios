import { describe, expect, it } from "vitest";
import { normalizeAudiobookSummary } from "@/lib/ai/audiobook-agent";
import { podcastSummarySchema } from "@/lib/contracts/daily-podcast";

describe("generated audiobook summaries", () => {
  it("preserves a valid summary", () => {
    expect(normalizeAudiobookSummary("  A short overview.  ")).toBe("A short overview.");
  });
  it.each([
    "公司公布融资消息，相关数据尚待核实。".repeat(50),
    "CopilotKit 融资研究包含公开数据和公司发展历程。".repeat(50),
    "A short sentence about the book. ".repeat(50),
    "extraordinarily ".repeat(199),
  ])("bounds generated text while preserving its opening", text => {
    const result = normalizeAudiobookSummary(text);
    expect(podcastSummarySchema.safeParse(result).success).toBe(true);
    expect(text.startsWith(result)).toBe(true);
    expect(result.length).toBeGreaterThan(0);
  });
  it("still rejects an empty summary", () => {
    expect(() => normalizeAudiobookSummary(" ")).toThrow();
  });
});
