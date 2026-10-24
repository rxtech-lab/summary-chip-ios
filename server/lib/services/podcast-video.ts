import { randomUUID } from "node:crypto";
import type { LanguageModelUsage } from "ai";
import type { AiProvider } from "@/lib/ai/provider";
import type { PodcastProgress, DailyPodcast, PodcastDay, PodcastScript, PodcastVideoSource, PodcastVideoSummary } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { PODCAST_VIDEO_FPS, PODCAST_VIDEO_HEIGHT, PODCAST_VIDEO_SCAFFOLD, PODCAST_VIDEO_WIDTH } from "@/lib/podcast-video/scaffold";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { getAiProvider } from "@/lib/ai/provider";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { PodcastTranslation } from "@/lib/contracts/daily-podcast";
import { dailyPodcastEpisode, dayKey, isTranslation, jsonObject, translationMissing, translationPath, updatePodcastDocument } from "./daily-podcast";
import { getSummaryForViewer, type ServiceDeps } from "./summaries";

type Script = Pick<PodcastScript, "title" | "mood" | "speakers" | "segments"> & { language: string };

/**
 * Asks the video agent to animate a script. Never throws: without a model, on failure or when it
 * runs out of time the episode simply has no video.
 */
export async function composePodcastVideo(ai: AiProvider, script: Script, chips: { id: string; title: string }[],
  abortSignal: AbortSignal, onUsage: (usage: LanguageModelUsage) => void, onProgress?: (percent: number) => void): Promise<PodcastVideoSource | null> {
  const model = ai.podcastVideoModelId();
  if (!model) return null;
  try {
    const files = await ai.writePodcastVideo({ title: script.title, language: script.language, mood: script.mood,
      speakers: script.speakers.map((speaker) => speaker.name), chips,
      segments: script.segments.map(({ speaker, chipId, caption }) => ({ speaker, chipId, caption })) }, { abortSignal, onUsage, onProgress });
    if (!files) return null;
    return { id: randomUUID(), model, createdAt: new Date().toISOString(), fps: PODCAST_VIDEO_FPS,
      width: PODCAST_VIDEO_WIDTH, height: PODCAST_VIDEO_HEIGHT, chips, files: { ...files, ...PODCAST_VIDEO_SCAFFOLD } };
  } catch (error) {
    console.error("[podcast] video composition failed, publishing without video", error);
    return null;
  }
}

/** Stores the composition next to the recording and returns the summary kept on the episode. */
export async function storePodcastVideo(store: ObjectStore, episodePath: string, source: PodcastVideoSource): Promise<PodcastVideoSummary> {
  await store.put(`${episodePath}/video.json`, jsonObject(source));
  return { id: source.id, createdAt: source.createdAt };
}

async function readVideoSource(store: ObjectStore, path: string) {
  const object = await store.get(`${path}/video.json`);
  return JSON.parse(new TextDecoder().decode(object.bytes)) as PodcastVideoSource;
}

/** The owner's composition to render on device, in `language` when it's a translation. No AI or points. */
export async function podcastVideoSource(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore(), language?: string | null): Promise<PodcastVideoSource> {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  const translated = isTranslation(podcast, language);
  const video = translated ? podcast.translations?.[language!]?.video : podcast.video;
  if (translated && !podcast.translations?.[language!]) throw translationMissing();
  if (!video) throw new ApiError(404, "PODCAST_VIDEO_MISSING", "This podcast has no video yet.");
  return readVideoSource(store, translated ? translationPath(user, podcast, language!) : `${dayKey(user, day)}/${key}`);
}

/**
 * Stores the original composition for a translation: the same scenes (the turns match one to one) with
 * translated chip titles and, when the model managed it safely, translated labels. Real timings arrive on device.
 */
export async function translatePodcastVideoSource(ai: AiProvider, store: ObjectStore, user: string, podcast: DailyPodcast, language: TranslationLanguage,
  chipTitles: Record<string, string>, abortSignal: AbortSignal, onUsage: (usage: LanguageModelUsage) => void): Promise<NonNullable<PodcastTranslation["video"]>> {
  const original = await readVideoSource(store, `${dayKey(user, podcast.day)}/${podcast.key}`);
  const generated = Object.fromEntries(Object.entries(original.files).filter(([path]) => !(path in PODCAST_VIDEO_SCAFFOLD)));
  const translated = await ai.translatePodcastVideo(generated, LANGUAGE_NAMES[language], { abortSignal, onUsage }).catch((error) => {
    console.error("[podcast] video label translation failed, keeping the original labels", error);
    return null;
  });
  const source: PodcastVideoSource = { ...original, id: randomUUID(), createdAt: new Date().toISOString(),
    chips: original.chips.map((chip) => ({ id: chip.id, title: chipTitles[chip.id] ?? chip.title })),
    files: { ...(translated ?? generated), ...PODCAST_VIDEO_SCAFFOLD } };
  await store.put(`${translationPath(user, podcast, language)}/video.json`, jsonObject(source));
  return { id: source.id, createdAt: source.createdAt, sourceId: original.id };
}

type ProgressListener = (progress: PodcastProgress) => void;
const writing = new Map<string, { promise: Promise<DailyPodcast>; listeners: Set<ProgressListener>; latest: PodcastProgress }>();

/**
 * Writes a new composition for a saved episode (an older one without video, or to try another look).
 * Spends points for the model's tokens; the previous composition and published render are replaced.
 */
export async function createPodcastVideo(db: Database, user: string, day: PodcastDay, key: string, deps: ServiceDeps = {}, onProgress?: ProgressListener,
  language?: TranslationLanguage): Promise<DailyPodcast> {
  const store = deps.store ?? getObjectStore();
  const lock = `${user}/${key}/${language ?? ""}`;
  const pending = writing.get(lock);
  if (pending) {
    if (onProgress) { pending.listeners.add(onProgress); onProgress(pending.latest); }
    try { return await pending.promise; }
    finally { if (onProgress) pending.listeners.delete(onProgress); }
  }
  const state = { promise: undefined as unknown as Promise<DailyPodcast>, listeners: new Set<ProgressListener>(),
    latest: { stage: "preparing", percent: 0 } as PodcastProgress };
  if (onProgress) state.listeners.add(onProgress);
  const report = (stage: PodcastProgress["stage"], percent: number, completedSteps?: number) => {
    state.latest = { stage, percent, completedSteps };
    for (const listener of state.listeners) { try { listener(state.latest); } catch { state.listeners.delete(listener); } }
  };
  report("preparing", 0);
  const run = (async () => {
    const podcast = await dailyPodcastEpisode(db, user, day, key);
    const translated = isTranslation(podcast, language);
    const translation = translated ? podcast.translations?.[language!] : undefined;
    if (translated && !translation) throw translationMissing();
    const ai = deps.ai ?? await getAiProvider();
    const model = ai.podcastVideoModelId();
    if (!model) throw new ApiError(503, "PODCAST_VIDEO_UNAVAILABLE", "Podcast videos are not available right now.");
    // A translation reuses the original composition, which is designed first when there is none.
    if (translation && podcast.video) {
      const charge = await reservePodcastPoints(user, `${key}:video:${language}:${randomUUID()}`, ai.tourModelId(), deps.billingEnvironment);
      try {
        const result = await translateVideo(ai, store, db, user, podcast, language!, translation, report);
        await charge?.settle(Math.max(1, pointsForCost(result.costUsd)), { translationCostUsd: result.costUsd });
        report("complete", 100);
        return result.podcast;
      } catch (error) {
        await charge?.settle(0, { failed: true });
        throw error;
      }
    }
    const chips = await Promise.all(podcast.chipIds.map(async (id) => {
      const chip = await getSummaryForViewer(db, id, user);
      return { id: chip.id, title: chip.title };
    }));
    const charge = await reservePodcastPoints(user, `${key}:video:${randomUUID()}`, model, deps.billingEnvironment);
    const usage: LanguageModelUsage[] = [];
    try {
      report("video-design", 10, 0);
      const source = await composePodcastVideo(ai, podcast, chips, AbortSignal.timeout(270_000), (step) => {
        usage.push(step);
      }, (percent) => report("video-design", 10 + Math.floor(percent * 0.8), usage.length));
      if (!source) throw new ApiError(502, "PODCAST_VIDEO_FAILED", "The video could not be created. Please try again.");
      report("saving", 90);
      const video = await storePodcastVideo(store, `${dayKey(user, day)}/${key}`, source);
      const stale: string[] = [];
      const saved = await updatePodcastDocument(db, user, key, (latest) => {
        if (latest.video?.published) stale.push(latest.video.published.videoId);
        latest.video = video;
        // Translated videos showed the replaced composition: each translation can make a new one from this.
        for (const other of Object.values(latest.translations ?? {})) {
          if (other.video?.published) stale.push(other.video.published.videoId);
          delete other.video;
        }
      });
      // Old renders show the replaced composition; share links fall back to audio until the new one is published.
      for (const videoId of stale) await store.delete(renderKey(user, day, key, videoId));
      let textCost = 0;
      if (translation) {
        // The translation's video follows in the same paid request.
        report("video-design", 92);
        const result = await translateVideo(ai, store, db, user, saved, language!, saved.translations![language!], () => {});
        textCost = result.costUsd;
        Object.assign(saved, result.podcast);
      }
      const pricing = charge ? await ai.podcastVideoPricing() : null;
      const cost = pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0;
      await charge?.settle(Math.max(1, pointsForCost(cost + textCost)), { videoCostUsd: cost, translationCostUsd: textCost });
      report("complete", 100);
      return saved;
    } catch (error) {
      await charge?.settle(0, { failed: true });
      throw error;
    }
  })().finally(() => writing.delete(lock));
  state.promise = run;
  writing.set(lock, state);
  return run;
}

/** Gives a translation the current original composition with translated labels. Billing is the caller's. */
async function translateVideo(ai: AiProvider, store: ObjectStore, db: Database, user: string, podcast: DailyPodcast, language: TranslationLanguage,
  translation: PodcastTranslation, report: (stage: PodcastProgress["stage"], percent: number) => void) {
  const usage: LanguageModelUsage[] = [];
  report("video-design", 10);
  const video = await translatePodcastVideoSource(ai, store, user, podcast, language, translation.chipTitles ?? {}, AbortSignal.timeout(200_000), (step) => usage.push(step));
  report("saving", 90);
  let stale: string | undefined;
  const saved = await updatePodcastDocument(db, user, podcast.key, (latest) => {
    const current = latest.translations?.[language];
    if (!current) throw translationMissing();
    stale = current.video?.published?.videoId;
    current.video = video;
  });
  if (stale) await store.delete(renderKey(user, podcast.day, podcast.key, stale));
  const pricing = usage.length ? await ai.tourPricing() : null;
  return { podcast: saved, costUsd: pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0 };
}

function renderKey(user: string, day: PodcastDay, key: string, videoId: string) {
  return `${dayKey(user, day)}/${key}/video/${videoId}.mp4`;
}
/** The video record of the requested language, which publication updates. */
function videoOf(podcast: DailyPodcast, language?: string | null) {
  if (!isTranslation(podcast, language)) return { get: () => podcast.video, set: (video: PodcastVideoSummary) => { podcast.video = video; } };
  const translation = podcast.translations?.[language!];
  if (!translation) throw translationMissing();
  return { get: () => translation.video as PodcastVideoSummary | undefined,
    set: (video: PodcastVideoSummary) => { translation.video = { ...translation.video, ...video }; } };
}
async function currentVideo(db: Database, user: string, day: PodcastDay, key: string, videoId: string, language?: string | null) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  // A render of a replaced composition is stale: the app re-renders the current one.
  if (videoOf(podcast, language).get()?.id !== videoId) throw new ApiError(409, "PODCAST_VIDEO_CHANGED", "The video changed. Render it again before publishing.");
  return podcast;
}

/** A presigned PUT for the app's render of the current composition. */
export async function createPodcastVideoUpload(db: Database, user: string, input: { day: PodcastDay; videoId: string; byteSize: number; language?: string }, key: string, store = getObjectStore()) {
  await currentVideo(db, user, input.day, key, input.videoId, input.language);
  const signed = await store.signedPut(renderKey(user, input.day, key, input.videoId), "video/mp4", input.byteSize);
  return { uploadUrl: signed.url, method: "PUT" as const, headers: signed.headers, expiresAt: signed.expiresAt.toISOString() };
}

/** Confirms the uploaded render, so share links play it. */
export async function publishPodcastVideo(db: Database, user: string, input: { day: PodcastDay; videoId: string; language?: string }, key: string, store = getObjectStore()) {
  await currentVideo(db, user, input.day, key, input.videoId, input.language);
  const head = await store.head(renderKey(user, input.day, key, input.videoId));
  if (!head?.byteSize) throw new ApiError(409, "UPLOAD_INCOMPLETE", "The video has not finished uploading.");
  if (head.contentType && head.contentType !== "video/mp4") throw new ApiError(422, "PODCAST_VIDEO_TYPE", "Upload the video as MP4.");
  return updatePodcastDocument(db, user, key, (latest) => {
    const video = videoOf(latest, input.language);
    if (video.get()?.id !== input.videoId) throw new ApiError(409, "PODCAST_VIDEO_CHANGED", "The video changed. Render it again before publishing.");
    video.set({ ...video.get()!, published: { videoId: input.videoId, byteSize: head.byteSize!, publishedAt: new Date().toISOString() } });
  });
}

/** Stops share links playing the video and deletes the uploaded render. */
export async function unpublishPodcastVideo(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore(), language?: string | null) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  const published = videoOf(podcast, language).get()?.published;
  if (!published) return podcast;
  const saved = await updatePodcastDocument(db, user, key, (latest) => {
    const video = videoOf(latest, language);
    if (video.get()) video.set({ ...video.get()!, published: undefined });
  });
  await store.delete(renderKey(user, day, key, published.videoId));
  return saved;
}

/** A short-lived URL to a published render, after the caller has checked the share link. */
/** `podcast` is the share link's episode in the listener's language (see `podcastInLanguage`). */
export async function publishedPodcastVideoUrl(owner: string, podcast: DailyPodcast, store = getObjectStore()) {
  const published = podcast.video?.published;
  if (!published || published.videoId !== podcast.video?.id) throw new ApiError(404, "NOT_FOUND", "Video not found");
  return (await store.signedGet(renderKey(owner, podcast.day, podcast.key, published.videoId),
    { filename: "podcast.mp4", inline: true, expiresInSeconds: 3600 })).url;
}
