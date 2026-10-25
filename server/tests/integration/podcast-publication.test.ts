import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { podcastArticle, publicationKey } from "@/lib/services/podcast-publication";
import type { DailyPodcast } from "@/lib/contracts/daily-podcast";
import { setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
beforeEach(async () => { env = await setupTestEnv(); });
afterEach(() => { vi.restoreAllMocks(); env.teardown(); });
const episode = { key: "episode", title: "Discovery", language: "en", segments: [
  { caption: "A scientific discovery.", startSeconds: 4, endSeconds: 10 },
] } as DailyPodcast;

it("coalesces article generation, persists it, and separates languages and revisions", async () => {
  const writer = vi.spyOn(env.ai, "writePodcastArticle");
  const [one, two] = await Promise.all([podcastArticle(episode), podcastArticle(episode)]);
  expect(one).toEqual(two);
  await podcastArticle(episode);
  expect(writer).toHaveBeenCalledTimes(1);
  const translation = { ...episode, language: "ja" };
  expect(publicationKey(translation)).not.toBe(publicationKey(episode));
  await podcastArticle(translation);
  expect(writer).toHaveBeenCalledTimes(2);
  expect(publicationKey({ ...episode, segments: [{ ...episode.segments[0], startSeconds: 5 }] })).not.toBe(publicationKey(episode));
});

it("does not persist an invalid timestamp reference and allows recovery after failure", async () => {
  const writer = vi.spyOn(env.ai, "writePodcastArticle");
  writer.mockResolvedValueOnce({ description: "Overview", sections: [{ heading: "Topic", paragraphs: ["An article."], segmentIndex: 99 }] });
  await expect(podcastArticle(episode)).rejects.toThrow("Invalid article timestamp reference");
  await expect(podcastArticle(episode)).resolves.toMatchObject({ sections: [{ segmentIndex: 0 }] });
  expect(writer).toHaveBeenCalledTimes(2);
});
