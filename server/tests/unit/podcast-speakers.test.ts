import { expect, it } from "vitest";
import { createDailyPodcastSchema } from "@/lib/contracts/daily-podcast";

const request = { day: { start: "2026-10-25T00:00:00Z", end: "2026-10-26T00:00:00Z" }, language: "en" };
it("accepts optional ordered names and trims whitespace", () => {
  expect(createDailyPodcastSchema.parse(request).speakerNames).toBeUndefined();
  expect(createDailyPodcastSchema.parse({ ...request, speakerNames: [" 小明 ", "Jane"] }).speakerNames).toEqual(["小明", "Jane"]);
});
it("rejects empty, oversized and excessive speaker names", () => {
  for (const speakerNames of [[], [" "], ["a".repeat(41)], ["A", "B", "C", "D", "E"]]) {
    expect(createDailyPodcastSchema.safeParse({ ...request, speakerNames }).success).toBe(false);
  }
});
