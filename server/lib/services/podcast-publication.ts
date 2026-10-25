import { createHash } from "node:crypto";
import { getAiProvider } from "@/lib/ai/provider";
import { podcastArticleSchema, type DailyPodcast } from "@/lib/contracts/daily-podcast";
import { generateOgImages } from "@/lib/og/generate";
import { getObjectStore } from "@/lib/storage/r2";
import { ApiError } from "@/lib/http/errors";

// Content-addressed sidecars avoid overwriting episode documents during video/translation jobs.
export function publicationKey(podcast: DailyPodcast) {
  const hash = createHash("sha256").update(JSON.stringify([podcast.key, podcast.language, podcast.title,
    podcast.segments.map(s => [s.caption, s.startSeconds, s.endSeconds])])).digest("hex");
  return `podcast-publications/v1/${hash}`;
}
const pending = new Map<string, Promise<unknown>>();
async function once<T>(key: string, task: () => Promise<T>): Promise<T> {
  const existing = pending.get(key);
  if (existing) return existing as Promise<T>;
  const result = task().finally(() => pending.delete(key));
  pending.set(key, result);
  return result;
}
export async function podcastArticle(podcast: DailyPodcast) {
  const key = `${publicationKey(podcast)}/article.json`;
  return once(key, async () => {
    const store = getObjectStore();
    try {
      return podcastArticleSchema.parse(JSON.parse(new TextDecoder().decode((await store.get(key)).bytes)));
    } catch (error) {
      if (!(error instanceof ApiError && error.status === 404)) throw error;
    }
    const article = podcastArticleSchema.parse(await (await getAiProvider()).writePodcastArticle(podcast));
    if (article.sections.some(s => s.segmentIndex >= podcast.segments.length)) throw new Error("Invalid article timestamp reference");
    await store.put(key, { bytes: new TextEncoder().encode(JSON.stringify(article)), contentType: "application/json", cacheControl: "private, no-store" });
    return article;
  });
}
export async function podcastCover(podcast: DailyPodcast) {
  const key = `${publicationKey(podcast)}/cover-v2.png`;
  return once(key, async () => {
    const store = getObjectStore();
    try { return await store.get(key); }
    catch (error) { if (!(error instanceof ApiError && error.status === 404)) throw error; }
    const images = await generateOgImages({ id: podcast.key, headline: podcast.title,
      summary: podcast.segments.map(s => s.caption).join(" ").slice(0, 2000), category: "Podcast", keywords: ["podcast"],
      theme: { colors: ["#171c46", "#5149a6", "#cdb9ec"], mode: "dark", accent: "#cdb9ec", emoji: "🎙️" },
      siteLabel: "Chippy Podcast", language: podcast.language, kind: "podcast" }, "illustration", await getAiProvider());
    const image = { bytes: images.card, contentType: "image/png", cacheControl: "private, no-store" };
    await store.put(key, image);
    return image;
  });
}
