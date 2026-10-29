import { queueDefaultPodcastRender, retirePodcastRenders } from "./podcast-render";
import { randomUUID } from "node:crypto";
import type { LanguageModelUsage } from "ai";
import type { AiProvider } from "@/lib/ai/provider";
import type { PodcastProgress, DailyPodcast, PodcastDay, PodcastVideoAsset, PodcastVideoSource, PodcastVideoStyle, PodcastVideoSummary } from "@/lib/contracts/daily-podcast";
import type { PreviewAsset } from "@/lib/podcast-video/frame-preview";
import { isPodcastVideoAsset } from "@/lib/podcast-video/images";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { PODCAST_VIDEO_PHRASES, PODCAST_VIDEO_SCAFFOLD } from "@/lib/podcast-video/scaffold";
import type { PodcastVideoInput } from "@/lib/ai/podcast-video-agent";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { getAiProvider } from "@/lib/ai/provider";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { PodcastTranslation } from "@/lib/contracts/daily-podcast";
import { dailyPodcastEpisode, dayKey, isTranslation, jsonObject, translationMissing, translationPath, updatePodcastDocument } from "./daily-podcast";
import { getSummaryForViewer, type ServiceDeps } from "./summaries";
import { startPodcastVideoDesign, waitForPodcastVideoDesign } from "./podcast-video-design";

type Episode = Pick<DailyPodcast, "title" | "mood" | "speakers" | "segments" | "durationSeconds"> & { language: string };

/**
 * The voiced episode as the video agent sees it: real turn and voice windows and the transcribed
 * phrases. Older episodes without timing get an estimate, with each turn as a single phrase.
 */
export function podcastVideoInput(podcast: Episode, chips: { id: string; title: string }[], style?: PodcastVideoStyle): PodcastVideoInput {
  let cursor = 0;
  const segments = podcast.segments.map((segment) => {
    const startSeconds = segment.startSeconds ?? cursor;
    const endSeconds = Math.max(startSeconds + 0.5, segment.endSeconds ?? startSeconds + Math.max(2, segment.caption.length * 0.06));
    cursor = endSeconds;
    const voiceStartSeconds = segment.voiceStartSeconds ?? startSeconds;
    const voiceEndSeconds = Math.max(voiceStartSeconds + 0.1, segment.voiceEndSeconds ?? endSeconds);
    const phrases = segment.captionCues?.length
      ? segment.captionCues.map(cue => ({ ...cue }))
      : [{ text: segment.caption, startSeconds: voiceStartSeconds, endSeconds: voiceEndSeconds }];
    return { speaker: segment.speaker, chipId: segment.chipId, caption: segment.caption, camera: segment.camera, startSeconds, endSeconds,
      voiceStartSeconds, voiceEndSeconds, image: segment.imagePath, icon: segment.icon, phrases,
      ...(segment.storyboard ? { storyboardImage: segment.storyboard.path, storyboardLayout: segment.storyboard.layout } : {}) };
  });
  return { title: podcast.title, language: podcast.language, mood: podcast.mood, speakers: podcast.speakers.map((speaker) => speaker.name), chips,
    durationSeconds: Math.max(podcast.durationSeconds ?? 0, cursor + 1), segments, ...(style ? { style } : {}) };
}

/** Stores the composition next to the recording and returns the summary kept on the episode. */
export async function storePodcastVideo(store: ObjectStore, episodePath: string, source: PodcastVideoSource): Promise<PodcastVideoSummary> {
  await store.put(`${episodePath}/video.json`, jsonObject(source));
  return { id: source.id, createdAt: source.createdAt };
}

async function readVideoSource(store: ObjectStore, path: string, sourceFile = "video.json") {
  const object = await store.get(`${path}/${sourceFile}`);
  return JSON.parse(new TextDecoder().decode(object.bytes)) as PodcastVideoSource;
}

/** The owner's composition to render on device, in `language` when it's a translation. No AI or points. */
export async function podcastVideoSource(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore(), language?: string | null): Promise<PodcastVideoSource> {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  const translated = isTranslation(podcast, language);
  const video = translated ? podcast.translations?.[language!]?.video : podcast.video;
  if (translated && !podcast.translations?.[language!]) throw translationMissing();
  if (!video) throw new ApiError(404, "PODCAST_VIDEO_MISSING", "This podcast has no video yet.");
  return readVideoSource(store, translated ? translationPath(user, podcast, language!) : `${dayKey(user, day)}/${key}`, video.sourceFile);
}

/** The original composition's generated cut-outs, or none when the episode has no video yet. */
export async function currentPodcastVideoAssets(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore()): Promise<PodcastVideoAsset[]> {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  if (!podcast.video) return [];
  const source = await readVideoSource(store, `${dayKey(user, day)}/${key}`, podcast.video.sourceFile);
  return (source.assets ?? []).filter(isPodcastVideoAsset);
}

/** Cut-out bytes by their public/ path, for frame previews. */
export async function podcastVideoAssetBytes(store: ObjectStore, user: string, day: PodcastDay, key: string, assets: PodcastVideoAsset[]): Promise<Record<string, PreviewAsset>> {
  const loaded: Record<string, PreviewAsset> = {};
  for (const asset of assets.filter(isPodcastVideoAsset)) {
    const object = await store.get(`${dayKey(user, day)}/${key}/${asset.file}`).catch(() => null);
    if (object) loaded[asset.path] = { bytes: object.bytes, width: asset.width, height: asset.height };
  }
  return loaded;
}

/** Short-lived download URLs for a composition's cut-outs, so the app can place them under public/. */
export async function podcastVideoAssetUrls(user: string, day: PodcastDay, key: string, source: PodcastVideoSource, store = getObjectStore()) {
  return Promise.all((source.assets ?? []).filter(isPodcastVideoAsset).map(async (asset) => ({
    path: asset.path, width: asset.width, height: asset.height,
    url: (await store.signedGet(`${dayKey(user, day)}/${key}/${asset.file}`, { expiresInSeconds: 3600 })).url,
  })));
}

/**
 * Stores the original composition for a translation: the same scenes (the turns match one to one) with
 * translated chip titles and, when the model managed it safely, translated labels. Real timings arrive on device.
 */
export async function translatePodcastVideoSource(ai: AiProvider, store: ObjectStore, user: string, podcast: DailyPodcast, language: TranslationLanguage,
  chipTitles: Record<string, string>, abortSignal: AbortSignal, onUsage: (usage: LanguageModelUsage) => void): Promise<NonNullable<PodcastTranslation["video"]>> {
  const original = await readVideoSource(store, `${dayKey(user, podcast.day)}/${podcast.key}`, podcast.video?.sourceFile);
  const generated = Object.fromEntries(Object.entries(original.files).filter(([path]) => !(path in PODCAST_VIDEO_SCAFFOLD) && path !== PODCAST_VIDEO_PHRASES));
  // Phrase timing is proportional, so the translation replays the original staging; older compositions have none.
  const phrases = original.files[PODCAST_VIDEO_PHRASES] ?? "[]";
  const translated = await ai.translatePodcastVideo(generated, LANGUAGE_NAMES[language], { abortSignal, onUsage }).catch((error) => {
    console.error("[podcast] video label translation failed, keeping the original labels", error);
    return null;
  });
  const source: PodcastVideoSource = { ...original, id: randomUUID(), createdAt: new Date().toISOString(),
    chips: original.chips.map((chip) => ({ id: chip.id, title: chipTitles[chip.id] ?? chip.title })),
    files: { ...(translated ?? generated), ...PODCAST_VIDEO_SCAFFOLD, [PODCAST_VIDEO_PHRASES]: phrases } };
  await store.put(`${translationPath(user, podcast, language)}/video.json`, jsonObject(source));
  return { id: source.id, createdAt: source.createdAt, sourceId: original.id };
}

type ProgressListener = (progress: PodcastProgress) => void;
const writing = new Map<string, { promise: Promise<DailyPodcast>; listeners: Set<ProgressListener>; latest: PodcastProgress }>();

/**
 * Designs a new composition for a saved episode (an older one without video, or to try another look).
 * The agent works in the background (`startPodcastVideoDesign`) and the episode comes back at once with
 * its `videoDesign` status; with `onProgress` this follows the run until it ends or the request nears its
 * limit. A translation of an episode that already has video only gets translated labels, right away.
 */
export async function createPodcastVideo(db: Database, user: string, day: PodcastDay, key: string, deps: ServiceDeps = {}, onProgress?: ProgressListener,
  language?: TranslationLanguage, style?: PodcastVideoStyle): Promise<DailyPodcast> {
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
      const charge = await reservePodcastPoints(user, `${key}:video:${language}:${randomUUID()}`, ai.podcastModelId(), deps.billingEnvironment);
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
    const started = await startPodcastVideoDesign(db, user, podcast, chips, { ...deps, ai, store }, { language: translated ? language : undefined, style, checkPoints: true });
    if (state.listeners.size === 0 || !started.videoDesign) return started;
    // Streaming clients (older apps) follow the run; it continues in the background past the request.
    return waitForPodcastVideoDesign(db, user, day, key, started.videoDesign.id, report, AbortSignal.timeout(270_000));
  })().finally(() => writing.delete(lock));
  state.promise = run;
  writing.set(lock, state);
  return run;
}

/** Gives a translation the current original composition with translated labels. Billing is the caller's. */
export async function translateVideo(ai: AiProvider, store: ObjectStore, db: Database, user: string, podcast: DailyPodcast, language: TranslationLanguage,
  translation: PodcastTranslation, report: (stage: PodcastProgress["stage"], percent: number) => void) {
  const usage: LanguageModelUsage[] = [];
  report("video-design", 10);
  const video = await translatePodcastVideoSource(ai, store, user, podcast, language, translation.chipTitles ?? {}, AbortSignal.timeout(200_000), (step) => usage.push(step));
  report("saving", 90);
  let stale: string | undefined;
  let retired: PodcastVideoSummary | undefined;
  const saved = await updatePodcastDocument(db, user, podcast.key, (latest) => {
    const current = latest.translations?.[language];
    if (!current) throw translationMissing();
    stale = current.video?.published?.videoId;
    retired = current.video;
    current.video = video;
  });
  if (stale) await store.delete(renderKey(user, podcast.day, podcast.key, stale));
  const pricing = usage.length ? await ai.podcastPricing() : null;
  await retirePodcastRenders(store, user, podcast.day, podcast.key, retired);
  await queueDefaultPodcastRender(db, user, podcast.day, podcast.key, language);
  return { podcast: saved, costUsd: pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0 };
}

export function renderKey(user: string, day: PodcastDay, key: string, videoId: string) {
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
