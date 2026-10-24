import { randomUUID } from "node:crypto";
import type { LanguageModelUsage } from "ai";
import { getAiProvider } from "@/lib/ai/provider";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { DailyPodcast, PodcastDay, PodcastProgress, PodcastTranslation } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore } from "@/lib/storage/r2";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import {
  dailyPodcastEpisode, dayKey, episodeAudioPath, storeContinuousAudio, translationMissing, translationPath,
  updatePodcastDocument, voiceSegments,
} from "./daily-podcast";
import { podcastMusic } from "./podcast-music";
import { translatePodcastVideoSource } from "./podcast-video";
import { getSummaryForViewer, type ServiceDeps } from "./summaries";

type ProgressListener = (progress: PodcastProgress) => void;
const writing = new Map<string, { promise: Promise<DailyPodcast>; listeners: Set<ProgressListener>; latest: PodcastProgress }>();

/**
 * Speaks a saved episode in another language: the script is translated turn for turn, voiced with the
 * same hosts, captioned, mixed with the same music, and the video reuses the original composition with
 * translated labels. Spends points; an existing translation is returned unchanged for free.
 * Returns the stored document (the route presents it in `language`).
 */
export async function translateDailyPodcast(db: Database, user: string, day: PodcastDay, key: string,
  input: { language: TranslationLanguage; includeVideo?: boolean }, deps: ServiceDeps = {}, onProgress?: ProgressListener): Promise<DailyPodcast> {
  const { language } = input;
  const lock = `${user}/${key}/${language}`;
  const pending = writing.get(lock);
  if (pending) {
    if (onProgress) { pending.listeners.add(onProgress); onProgress(pending.latest); }
    try { return await pending.promise; }
    finally { if (onProgress) pending.listeners.delete(onProgress); }
  }
  const state = { promise: undefined as unknown as Promise<DailyPodcast>, listeners: new Set<ProgressListener>(),
    latest: { stage: "preparing", percent: 0 } as PodcastProgress };
  if (onProgress) state.listeners.add(onProgress);
  const report = (stage: PodcastProgress["stage"], percent: number, completedSegments?: number, totalSegments?: number) => {
    state.latest = { stage, percent, completedSegments, totalSegments };
    for (const listener of state.listeners) { try { listener(state.latest); } catch { state.listeners.delete(listener); } }
  };
  report("preparing", 0);
  const run = (async () => {
    const store = deps.store ?? getObjectStore();
    const podcast = await dailyPodcastEpisode(db, user, day, key);
    if (language === podcast.language) throw new ApiError(422, "PODCAST_TRANSLATION_SAME", "The podcast is already in this language.");
    if (podcast.translations?.[language]) { report("complete", 100); return podcast; }
    const ai = deps.ai ?? await getAiProvider();
    if (!ai.speechModelId()) throw new ApiError(503, "PODCAST_SPEECH_UNAVAILABLE", "Podcast audio is not available right now.");
    const chips = await Promise.all(podcast.chipIds.map(async (id) => {
      const chip = await getSummaryForViewer(db, id, user);
      return { id: chip.id, title: chip.title };
    }));
    const charge = await reservePodcastPoints(user, `${key}:translation:${language}:${randomUUID()}`, ai.tourModelId(), deps.billingEnvironment);
    const usage: LanguageModelUsage[] = [];
    const deadline = AbortSignal.timeout(270_000);
    try {
      report("translating", 5);
      const translated = await ai.translatePodcast({ language: LANGUAGE_NAMES[language], title: podcast.title, chips,
        segments: podcast.segments.map((segment) => ({ speaker: podcast.speakers[segment.speaker]?.name ?? "", caption: segment.caption })) },
      { abortSignal: AbortSignal.any([deadline, AbortSignal.timeout(100_000)]), onUsage: (step) => usage.push(step) });
      if (translated.captions.length !== podcast.segments.length || translated.chipTitles.length !== chips.length) {
        throw new Error("Translated podcast doesn't match the original turns");
      }
      const chipTitles = Object.fromEntries(chips.map((chip, index) => [chip.id, translated.chipTitles[index]]));
      // The same mood's clips are already stored, so music is usually free; it is skipped when the original had none.
      const musicTask = podcast.music ? podcastMusic(ai, store, podcast.mood, deadline) : Promise.resolve(null);
      report("speech", 20, 0, podcast.segments.length);
      const voiced = await voiceSegments(ai, podcast.speakers, podcast.segments.map((segment, index) => ({
        speaker: segment.speaker, chipId: segment.chipId, caption: translated.captions[index],
        imagePath: segment.imagePath, icon: segment.icon,
      })), deadline, (completed, total) => report("speech", 20 + Math.floor(50 * completed / total), completed, total));
      const translation: PodcastTranslation = { language, title: translated.title, createdAt: (deps.now?.() ?? new Date()).toISOString(),
        speakers: podcast.speakers, segments: voiced.segments, chipTitles };
      report("music", 70);
      const music = await musicTask;
      report("mixing", 75);
      const base = translationPath(user, podcast, language);
      await storeContinuousAudio(store, `${base}/audio.mp3`, episodeAudioPath(podcast, language), translation, voiced.audioParts, music);
      if (podcast.video && input.includeVideo !== false) {
        report("video-design", 85);
        translation.video = await translatePodcastVideoSource(ai, store, user, podcast, language, chipTitles,
          AbortSignal.any([deadline, AbortSignal.timeout(120_000)]), (step) => usage.push(step));
      }
      report("saving", 95);
      const saved = await updatePodcastDocument(db, user, key, (latest) => {
        latest.translations = { ...latest.translations, [language]: translation };
      });
      const pricing = charge ? await ai.tourPricing() : null;
      const textCost = pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0;
      const speechCost = translation.segments.reduce((sum, segment) => sum + segment.caption.length, 0) * ai.speechUsdPerCharacter();
      const musicCost = (music?.generatedClips ?? 0) * ai.musicUsdPerClip();
      await charge?.settle(Math.max(1, pointsForCost(textCost + speechCost + musicCost)),
        { translation: language, segments: translation.segments.length, textCostUsd: textCost, speechCostUsd: speechCost, musicCostUsd: musicCost });
      report("complete", 100);
      return saved;
    } catch (error) {
      await charge?.settle(0, { failed: true });
      if (error instanceof ApiError) throw error;
      console.error("[podcast] translation failed", error);
      throw new ApiError(502, "PODCAST_TRANSLATION_FAILED", "The podcast could not be translated. Please try again.");
    }
  })().finally(() => writing.delete(lock));
  state.promise = run;
  writing.set(lock, state);
  return run;
}

/** Removes a translation, its recording, composition and published render. Its language stops playing at once. */
export async function removePodcastTranslation(db: Database, user: string, day: PodcastDay, key: string, language: string, deps: ServiceDeps = {}) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  const translation = podcast.translations?.[language];
  if (!translation) throw translationMissing();
  const saved = await updatePodcastDocument(db, user, key, (latest) => {
    delete latest.translations?.[language];
  });
  const store = deps.store ?? getObjectStore();
  const base = translationPath(user, podcast, language);
  const published = translation.video?.published?.videoId;
  await Promise.all([store.delete(`${base}/audio.mp3`), translation.video && store.delete(`${base}/video.json`),
    published && store.delete(`${dayKey(user, day)}/${key}/video/${published}.mp4`)]);
  return saved;
}
