import { randomUUID } from "node:crypto";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { AudiobookVideoTheme, DailyPodcast, PodcastDay, PodcastVideoDesign, PodcastVideoSource, PodcastVideoSummary } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { backgroundJobs } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { pointsForCost, reservePodcastPoints } from "@/lib/subscription/chat-billing";
import { getAudiobookStarter } from "./audiobook-starter";
import { sceneFile, sceneHash } from "./audiobooks";
import { recordJobActivity } from "./background-jobs";
import { dailyPodcastEpisode, dayKey, jsonObject, translationPath, updatePodcastDocument } from "./daily-podcast";
import { queueDefaultPodcastRender, retirePodcastRenders } from "./podcast-render";
import { renderKey, storePodcastVideo } from "./podcast-video";

/** One image-first video: plain data, the input of `workflows/design-audiobook-video.ts`. */
export interface AudiobookVideoJob {
  id: string;
  userId: string;
  key: string;
  day: PodcastDay;
  theme: AudiobookVideoTheme;
  billingEnvironment?: BillingEnvironment;
}
interface Deps { ai?: AiProvider; store?: ObjectStore; now?: () => Date; billingEnvironment?: BillingEnvironment }

const IMAGE_BATCH = 6;
const STALE_MS = 20 * 60_000;

function episodePath(job: Pick<AudiobookVideoJob, "userId" | "day" | "key">) { return `${dayKey(job.userId, job.day)}/${job.key}`; }
function statePath(job: AudiobookVideoJob) { return `${episodePath(job)}/video-design/${job.id}.json`; }
interface DrawState { costUsd: number; drawn: number; failed: string[] }

/** The scenes in order with the object each is stored as, under the job's theme. */
function scenesOf(podcast: DailyPodcast, theme: AudiobookVideoTheme) {
  const details = podcast.audiobook;
  if (!details) return [];
  return details.scenes.map(scene => ({ ...scene, hash: sceneHash(scene.prompt, { videoTheme: theme, visualGuide: details.visualGuide }) }));
}

/**
 * Starts illustrating a saved audiobook in the background, reusing the episode's `videoDesign` status and Background Jobs,
 * so the app follows it like any other video. Scenes come from the reviewed plan, and images drawn during review are reused.
 */
export async function startAudiobookVideo(db: Database, user: string, podcast: DailyPodcast, deps: Deps, options: { theme?: AudiobookVideoTheme }): Promise<DailyPodcast> {
  const design = podcast.videoDesign;
  if (design && !design.error && Date.now() - Date.parse(design.updatedAt) < STALE_MS) return podcast;
  const ai = deps.ai ?? await getAiProvider();
  const model = ai.imageModelId();
  if (!model || !podcast.audiobook) throw new ApiError(503, "PODCAST_VIDEO_UNAVAILABLE", "Audiobook videos are not available right now.");
  if (!podcast.audiobook.scenes.length) throw new ApiError(422, "AUDIOBOOK_NO_SCENES", "This audiobook was planned without scenes. Make a new version with video.");
  const theme = options.theme ?? podcast.audiobook.videoTheme;
  const job: AudiobookVideoJob = { id: randomUUID(), userId: user, key: podcast.key, day: podcast.day, theme, billingEnvironment: deps.billingEnvironment };
  const store = deps.store ?? getObjectStore();
  const check = await reservePodcastPoints(user, `${podcast.key}:video:${job.id}`, model, deps.billingEnvironment,
    Math.max(1, pointsForCost(podcast.audiobook.scenes.length * ai.imageUsdPerImage())));
  await check?.settle(0, { check: true });
  await store.put(statePath(job), jsonObject({ costUsd: 0, drawn: 0, failed: [] } satisfies DrawState));
  const now = (deps.now?.() ?? new Date()).toISOString();
  const started: PodcastVideoDesign = { id: job.id, startedAt: now, updatedAt: now, percent: 5 };
  await updatePodcastDocument(db, user, podcast.key, (latest) => { latest.videoDesign = started; if (latest.audiobook) latest.audiobook.videoTheme = theme; });
  await db.insert(backgroundJobs).values({ id: job.id, ownerId: user, episodeKey: podcast.key, createdAt: new Date(now),
    document: { id: job.id, title: podcast.title, episodeKey: podcast.key, day: podcast.day, status: "running", percent: 5, createdAt: now, updatedAt: now,
      logs: [{ id: "queued", at: now, message: "Queued scene illustrations. You can close the app while they're drawn." }] } });
  try { await getAudiobookStarter().startVideo(job); }
  catch (error) {
    console.error("[audiobook-video] could not start", error);
    await recordJobActivity(db, user, job.id, "failed", "The background job could not start. Open the audiobook to try again.", { status: "failed" });
    await updatePodcastDocument(db, user, podcast.key, (latest) => { if (latest.videoDesign?.id === job.id) delete latest.videoDesign; });
    throw new ApiError(503, "PODCAST_VIDEO_UNAVAILABLE", "The video could not be started right now. Please try again.");
  }
  return dailyPodcastEpisode(db, user, podcast.day, podcast.key);
}

/** Draws the next few missing scenes. Returns whether all are drawn; a scene that fails twice is left out of the video. */
export async function drawAudiobookVideoScenes(db: Database, job: AudiobookVideoJob, deps: Deps = {}): Promise<boolean> {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const podcast = await dailyPodcastEpisode(db, job.userId, job.day, job.key);
  if (podcast.videoDesign?.id !== job.id) return true;
  const state = JSON.parse(new TextDecoder().decode((await store.get(statePath(job))).bytes)) as DrawState;
  const details = podcast.audiobook!;
  const scenes = [...new Map(scenesOf(podcast, job.theme).map(scene => [scene.hash, scene])).values()];
  const present = await Promise.all(scenes.map(async scene => !!await store.head(`${episodePath(job)}/${sceneFile(scene.hash)}`)));
  const missing = scenes.filter((scene, index) => !present[index] && state.failed.filter(hash => hash === scene.hash).length < 2);
  await Promise.all(missing.slice(0, IMAGE_BATCH).map(async (scene) => {
    state.costUsd += ai.imageUsdPerImage();
    try {
      const image = await ai.drawAudiobookScene({ prompt: scene.prompt, theme: job.theme, visualGuide: details.visualGuide }, { abortSignal: AbortSignal.timeout(200_000) });
      await store.put(`${episodePath(job)}/${sceneFile(scene.hash)}`, { bytes: image.png, contentType: "image/png", cacheControl: "private, max-age=31536000, immutable" });
      state.drawn += 1;
    } catch (error) {
      state.failed.push(scene.hash);
      console.warn("[audiobook-video] scene failed", { job: job.id, message: (error instanceof Error ? error.message : String(error)).slice(0, 300) });
    }
  }));
  await store.put(statePath(job), jsonObject(state));
  const remaining = missing.length - Math.min(IMAGE_BATCH, missing.length);
  const percent = 5 + Math.floor(85 * (scenes.length - remaining) / Math.max(1, scenes.length));
  await updatePodcastDocument(db, job.userId, job.key, (latest) => {
    if (latest.videoDesign?.id === job.id) latest.videoDesign = { ...latest.videoDesign, updatedAt: new Date().toISOString(), percent };
  });
  await recordJobActivity(db, job.userId, job.id, "drawing", `Illustrated ${scenes.length - remaining} of ${scenes.length} scenes.`, { percent });
  return remaining === 0;
}

/** The composition from the scenes that exist: each runs from its turn to the next scene. */
async function sourceFrom(store: ObjectStore, job: AudiobookVideoJob, podcast: DailyPodcast, model: string): Promise<PodcastVideoSource | null> {
  const scenes = [];
  for (const scene of scenesOf(podcast, job.theme)) {
    if (await store.head(`${episodePath(job)}/${sceneFile(scene.hash)}`)) scenes.push({ file: sceneFile(scene.hash), segment: scene.segment, motion: scene.motion });
  }
  if (!scenes.length) return null;
  // The first picture is up from the opening music, before the first turn.
  scenes[0].segment = 0;
  return { id: job.id, model, createdAt: new Date().toISOString(), fps: 24, width: 1920, height: 1080, chips: [], files: {}, imageSequence: { scenes } };
}

/** Saves the composition in place of the previous one, gives each translation its copy, charges, and queues the renders. */
export async function finishAudiobookVideo(db: Database, job: AudiobookVideoJob, failed: boolean, deps: Deps = {}) {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const podcast = await dailyPodcastEpisode(db, job.userId, job.day, job.key).catch(() => null);
  if (podcast?.video?.id === job.id) return;
  if (!podcast || podcast.videoDesign?.id !== job.id) {
    await recordJobActivity(db, job.userId, job.id, "replaced", "This video was replaced or its audiobook was removed.", { status: "failed" });
    return;
  }
  const state = JSON.parse(new TextDecoder().decode((await store.get(statePath(job)).catch(() => ({ bytes: new TextEncoder().encode('{"costUsd":0}') }))).bytes)) as DrawState;
  const model = ai.imageModelId() ?? "image";
  const source = failed ? null : await sourceFrom(store, job, podcast, model);
  const hold = await reservePodcastPoints(job.userId, `${job.key}:video:${job.id}:charge`, model, job.billingEnvironment).catch(() => null);
  // Rebuilding from scenes already drawn, as merging chapters does, costs nothing.
  await hold?.settle(source && state.costUsd > 0 ? Math.max(1, pointsForCost(state.costUsd)) : 0, { imageCostUsd: state.costUsd, failed: !source });
  if (!source) {
    const error = { code: "PODCAST_VIDEO_FAILED", message: "The scenes couldn't be illustrated. Open the audiobook to retry." };
    await recordJobActivity(db, job.userId, job.id, "failed", error.message, { status: "failed", error });
    await updatePodcastDocument(db, job.userId, job.key, (latest) => { if (latest.videoDesign?.id === job.id) latest.videoDesign = { ...latest.videoDesign, updatedAt: new Date().toISOString(), error }; });
    await store.delete(statePath(job)).catch(() => undefined);
    return;
  }
  const video = await storePodcastVideo(store, episodePath(job), source);
  const stale: string[] = [];
  const retired: PodcastVideoSummary[] = [];
  const languages = Object.keys(podcast.translations ?? {});
  // Stills need no label translation, so every language follows the new composition at once.
  const clones = await Promise.all(languages.map(language => cloneSource(store, job.userId, podcast, language, source)));
  await updatePodcastDocument(db, job.userId, job.key, (latest) => {
    if (latest.video) { retired.push(latest.video); if (latest.video.published) stale.push(latest.video.published.videoId); }
    latest.video = video;
    languages.forEach((language, index) => {
      const translation = latest.translations?.[language];
      if (!translation) return;
      if (translation.video) { retired.push(translation.video); if (translation.video.published) stale.push(translation.video.published.videoId); }
      translation.video = clones[index];
    });
    delete latest.videoDesign;
  });
  for (const videoId of stale) await store.delete(renderKey(job.userId, job.day, job.key, videoId));
  for (const item of retired) await retirePodcastRenders(store, job.userId, job.day, job.key, item);
  await store.delete(statePath(job)).catch(() => undefined);
  await recordJobActivity(db, job.userId, job.id, "ready", "Scenes ready. HD video will render in the cloud.", { status: "ready", percent: 100, videoId: source.id });
  await queueDefaultPodcastRender(db, job.userId, job.day, job.key);
  for (const language of languages) await queueDefaultPodcastRender(db, job.userId, job.day, job.key, language);
}

async function cloneSource(store: ObjectStore, user: string, podcast: DailyPodcast, language: string, source: PodcastVideoSource) {
  const copy: PodcastVideoSource = { ...source, id: randomUUID(), createdAt: new Date().toISOString() };
  await store.put(`${translationPath(user, podcast, language)}/video.json`, jsonObject(copy));
  return { id: copy.id, createdAt: copy.createdAt, sourceId: source.id };
}

/** Gives a new translation the original's scenes, replayed against its own timings, and queues its render. */
export async function cloneAudiobookVideo(db: Database, user: string, podcast: DailyPodcast, language: TranslationLanguage, store: ObjectStore = getObjectStore()) {
  const original = JSON.parse(new TextDecoder().decode((await store.get(`${dayKey(user, podcast.day)}/${podcast.key}/video.json`)).bytes)) as PodcastVideoSource;
  const video = await cloneSource(store, user, podcast, language, original);
  await updatePodcastDocument(db, user, podcast.key, (latest) => { const translation = latest.translations?.[language]; if (translation) translation.video = video; });
  await queueDefaultPodcastRender(db, user, podcast.day, podcast.key, language);
}

/** Runs a video's steps in this process, as the workflow does. For tests and local tools. */
export async function runAudiobookVideoJob(db: Database, job: AudiobookVideoJob, deps: Deps = {}) {
  while (!await drawAudiobookVideoScenes(db, job, deps)) { /* the next step continues */ }
  await finishAudiobookVideo(db, job, false, deps);
}
