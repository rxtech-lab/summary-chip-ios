import { randomUUID } from "node:crypto";
import { and, eq, isNull } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { podcastEpisodes, summaries } from "@/lib/db/schema";
import type { PodcastDay, PodcastVideoSource } from "@/lib/contracts/daily-podcast";
import { isPodcastVideoAsset } from "@/lib/podcast-video/images";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore } from "@/lib/storage/r2";
import { dailyPodcastEpisode, dayKey, episodeAudioPath } from "./daily-podcast";

/** Fork a saved recording/composition for editing, without generating another chip or speech. */
export async function createPodcastVersion(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore()) {
  const original = await dailyPodcastEpisode(db, user, day, key);
  if (!original.audioPath) throw new ApiError(422, "PODCAST_AUDIO_MISSING", "This episode has no saved recording to version.");
  const episode = structuredClone(original);
  episode.key = randomUUID();
  episode.createdAt = new Date().toISOString();
  episode.audioPath = episodeAudioPath(episode);
  delete episode.videoDesign;
  delete episode.originalLanguage;
  delete episode.languages;
  const from = `${dayKey(user, day)}/${key}`;
  const to = `${dayKey(user, day)}/${episode.key}`;
  const copied: string[] = [];
  const copy = async (path: string) => {
    if (copied.includes(`${to}/${path}`)) return;
    const object = await store.get(`${from}/${path}`);
    copied.push(`${to}/${path}`);
    await store.put(`${to}/${path}`, object);
  };
  /** A composition and the generated cut-outs it uses (episode-relative, so shared by its translations). */
  const copyVideo = async (path: string) => {
    await copy(path);
    const source = JSON.parse(new TextDecoder().decode((await store.get(`${from}/${path}`)).bytes)) as PodcastVideoSource;
    for (const asset of source.assets ?? []) if (isPodcastVideoAsset(asset)) await copy(asset.file);
  };
  try {
    await copy("audio.mp3");
    if (episode.video) {
      await copyVideo(episode.video.sourceFile ?? "video.json");
      delete episode.video.published;
      delete episode.video.renders;
    }
    for (const [language, translation] of Object.entries(episode.translations ?? {})) {
      await copy(`translations/${language}/audio.mp3`);
      translation.audioPath = episodeAudioPath(episode, language);
      if (translation.video) {
        await copyVideo(`translations/${language}/${translation.video.sourceFile ?? "video.json"}`);
        delete translation.video.published;
        delete translation.video.renders;
      }
    }
    await dailyPodcastEpisode(db, user, day, key);
    await db.transaction(async tx => {
      const [live] = await tx.select({ key: podcastEpisodes.key }).from(podcastEpisodes).where(and(eq(podcastEpisodes.key, key), eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false)));
      if (!live) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
      const scope = episode.summaryId
        ? and(eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.summaryId, episode.summaryId))
        : and(eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.dayStart, Date.parse(day.start)), eq(podcastEpisodes.dayEnd, Date.parse(day.end)), isNull(podcastEpisodes.summaryId));
      await tx.update(podcastEpisodes).set({ isDefault: false }).where(scope);
      if (episode.summaryId) {
        await tx.update(summaries).set({ title: episode.title, summary: episode.segments.map(s => s.caption).join(" ").slice(0, 1200), language: episode.language, updatedAt: new Date() })
          .where(and(eq(summaries.id, episode.summaryId), eq(summaries.ownerId, user)));
      }
      await tx.insert(podcastEpisodes).values({ key: episode.key, ownerId: user, dayStart: Date.parse(day.start), dayEnd: Date.parse(day.end),
        summaryId: episode.summaryId ?? null, isDefault: true, document: episode });
    });
    return episode;
  } catch (error) {
    await Promise.allSettled(copied.map(path => store.delete(path)));
    throw error;
  }
}
