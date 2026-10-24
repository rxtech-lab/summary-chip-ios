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
import { dailyPodcastEpisode, dayKey, jsonObject, savePodcastDocument } from "./daily-podcast";
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

/** The owner's composition to render on device. No AI or points. */
export async function podcastVideoSource(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore()): Promise<PodcastVideoSource> {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  if (!podcast.video) throw new ApiError(404, "PODCAST_VIDEO_MISSING", "This podcast has no video yet.");
  const object = await store.get(`${dayKey(user, day)}/${key}/video.json`);
  return JSON.parse(new TextDecoder().decode(object.bytes)) as PodcastVideoSource;
}

type ProgressListener = (progress: PodcastProgress) => void;
const writing = new Map<string, { promise: Promise<DailyPodcast>; listeners: Set<ProgressListener>; latest: PodcastProgress }>();

/**
 * Writes a new composition for a saved episode (an older one without video, or to try another look).
 * Spends points for the model's tokens; the previous composition and published render are replaced.
 */
export async function createPodcastVideo(db: Database, user: string, day: PodcastDay, key: string, deps: ServiceDeps = {}, onProgress?: ProgressListener): Promise<DailyPodcast> {
  const store = deps.store ?? getObjectStore();
  const pending = writing.get(`${user}/${key}`);
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
    const ai = deps.ai ?? await getAiProvider();
    const model = ai.podcastVideoModelId();
    if (!model) throw new ApiError(503, "PODCAST_VIDEO_UNAVAILABLE", "Podcast videos are not available right now.");
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
      const stale = podcast.video?.published;
      podcast.video = await storePodcastVideo(store, `${dayKey(user, day)}/${key}`, source);
      await savePodcastDocument(db, user, podcast);
      // The old render shows the replaced composition; share links fall back to audio until the new one is published.
      if (stale) await store.delete(renderKey(user, day, key, stale.videoId));
      const pricing = charge ? await ai.podcastVideoPricing() : null;
      const cost = pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0;
      await charge?.settle(Math.max(1, pointsForCost(cost)), { videoCostUsd: cost });
      report("complete", 100);
      return podcast;
    } catch (error) {
      await charge?.settle(0, { failed: true });
      throw error;
    }
  })().finally(() => writing.delete(`${user}/${key}`));
  state.promise = run;
  writing.set(`${user}/${key}`, state);
  return run;
}

function renderKey(user: string, day: PodcastDay, key: string, videoId: string) {
  return `${dayKey(user, day)}/${key}/video/${videoId}.mp4`;
}
async function currentVideo(db: Database, user: string, day: PodcastDay, key: string, videoId: string) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  // A render of a replaced composition is stale: the app re-renders the current one.
  if (podcast.video?.id !== videoId) throw new ApiError(409, "PODCAST_VIDEO_CHANGED", "The video changed. Render it again before publishing.");
  return podcast;
}

/** A presigned PUT for the app's render of the current composition. */
export async function createPodcastVideoUpload(db: Database, user: string, input: { day: PodcastDay; videoId: string; byteSize: number }, key: string, store = getObjectStore()) {
  await currentVideo(db, user, input.day, key, input.videoId);
  const signed = await store.signedPut(renderKey(user, input.day, key, input.videoId), "video/mp4", input.byteSize);
  return { uploadUrl: signed.url, method: "PUT" as const, headers: signed.headers, expiresAt: signed.expiresAt.toISOString() };
}

/** Confirms the uploaded render, so share links play it. */
export async function publishPodcastVideo(db: Database, user: string, input: { day: PodcastDay; videoId: string }, key: string, store = getObjectStore()) {
  const podcast = await currentVideo(db, user, input.day, key, input.videoId);
  const head = await store.head(renderKey(user, input.day, key, input.videoId));
  if (!head?.byteSize) throw new ApiError(409, "UPLOAD_INCOMPLETE", "The video has not finished uploading.");
  if (head.contentType && head.contentType !== "video/mp4") throw new ApiError(422, "PODCAST_VIDEO_TYPE", "Upload the video as MP4.");
  podcast.video = { ...podcast.video!, published: { videoId: input.videoId, byteSize: head.byteSize, publishedAt: new Date().toISOString() } };
  await savePodcastDocument(db, user, podcast);
  return podcast;
}

/** Stops share links playing the video and deletes the uploaded render. */
export async function unpublishPodcastVideo(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore()) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  const published = podcast.video?.published;
  if (!published) return podcast;
  podcast.video = { ...podcast.video!, published: undefined };
  await savePodcastDocument(db, user, podcast);
  await store.delete(renderKey(user, day, key, published.videoId));
  return podcast;
}

/** A short-lived URL to a published render, after the caller has checked the share link. */
export async function publishedPodcastVideoUrl(owner: string, podcast: DailyPodcast, store = getObjectStore()) {
  const published = podcast.video?.published;
  if (!published || published.videoId !== podcast.video?.id) throw new ApiError(404, "NOT_FOUND", "Video not found");
  return (await store.signedGet(renderKey(owner, podcast.day, podcast.key, published.videoId),
    { filename: "podcast.mp4", inline: true, expiresInSeconds: 3600 })).url;
}
