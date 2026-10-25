import { afterEach, expect, it, vi } from "vitest";
import { DEFAULT_PODCAST_MODEL, podcastModelId } from "@/lib/ai/models";

afterEach(() => vi.unstubAllEnvs());

it("uses a dedicated default even when general and tour models differ", () => {
  vi.stubEnv("AI_MODEL", "general/model");
  vi.stubEnv("AI_TOUR_MODEL", "tour/model");
  vi.stubEnv("AI_PODCAST_MODEL", "");
  expect(podcastModelId()).toBe(DEFAULT_PODCAST_MODEL);
  vi.stubEnv("AI_PODCAST_MODEL", "   ");
  expect(podcastModelId()).toBe(DEFAULT_PODCAST_MODEL);
});

it("uses the configured podcast model after trimming whitespace", () => {
  vi.stubEnv("AI_PODCAST_MODEL", "  podcast/custom  ");
  expect(podcastModelId()).toBe("podcast/custom");
});
