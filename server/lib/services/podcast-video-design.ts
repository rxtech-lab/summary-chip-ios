import { queueDefaultPodcastRender, retirePodcastRenders } from "./podcast-render";
import { backgroundJobs } from "@/lib/db/schema";
import { recordJobActivity, notifyBackgroundJob } from "./background-jobs";
import { podcastVideoError } from "./podcast-video-error";
import { randomUUID } from "node:crypto";
import type { LanguageModelUsage } from "ai";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { estimateVideoProgress } from "@/lib/ai/podcast-progress";
import { newPodcastVideoDraft, PodcastVideoNoToolError, podcastVideoDraftFinished, podcastVideoProgressContext, PODCAST_VIDEO_MAX_TURNS,
  type PodcastVideoDraft, type PodcastVideoInput } from "@/lib/ai/podcast-video-agent";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { DailyPodcast, PodcastDay, PodcastProgress, PodcastVideoDesign, PodcastVideoStyle, PodcastVideoSummary } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { PODCAST_VIDEO_FPS, PODCAST_VIDEO_HEIGHT, PODCAST_VIDEO_PHRASES, PODCAST_VIDEO_SCAFFOLD, PODCAST_VIDEO_WIDTH, podcastPhraseWindows } from "@/lib/podcast-video/scaffold";
import { getPodcastVideoDesigner } from "@/lib/podcast-video/designer";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { dailyPodcastEpisode, dayKey, jsonObject, updatePodcastDocument } from "./daily-podcast";
import { podcastVideoInput, renderKey, storePodcastVideo, translateVideo } from "./podcast-video";

/** One background design: plain data, the input of `workflows/design-podcast-video.ts`. */
export interface PodcastVideoJob {
  /** Matches the episode's `videoDesign.id` while this run is the current one. */
  id: string;
  /** The owner, who pays. */
  userId: string;
  key: string;
  day: PodcastDay;
  /** A translation that gets the new composition's labels once it is saved. */
  language?: TranslationLanguage;
  billingEnvironment?: BillingEnvironment;
}

export type PodcastVideoOutcome =
  | { status: "running" }
  | { status: "accepted" }
  /** Nothing more can be done: the agent gave up, the model kept failing, or a newer run replaced this one. */
  | { status: "failed"; code: string; error?: { code: string; message: string } };

/** Turns a workflow runs at most: every agent turn plus a few failed model calls. */
const PODCAST_VIDEO_DESIGN_TURNS = PODCAST_VIDEO_MAX_TURNS + 3;
/** Model calls that may fail in a row before the run gives up. */
const MAX_FAILED_TURNS = 3;
/** One turn writes one small file or edit, so it finishes well within a function invocation. */
const TURN_TIMEOUT_MS = 240_000;
/** A run that hasn't saved a turn for this long has stopped; another may replace it. */
const STALE_MS = 20 * 60_000;

interface DesignState {
  input: PodcastVideoInput;
  chips: { id: string; title: string }[];
  draft: PodcastVideoDraft;
  /** Model cost so far, in USD, charged once when the run ends. */
  costUsd: number;
  failures: number;
  /** Highest composition progress observed (0–90). */
  progress: number;
  lastError?: { code: string; message: string };
}

type Deps = { ai?: AiProvider; store?: ObjectStore; now?: () => Date };

function statePath(job: Pick<PodcastVideoJob, "userId" | "day" | "key" | "id">) {
  return `${dayKey(job.userId, job.day)}/${job.key}/video-design/${job.id}.json`;
}
async function readState(store: ObjectStore, job: PodcastVideoJob): Promise<DesignState | null> {
  try { return JSON.parse(new TextDecoder().decode((await store.get(statePath(job))).bytes)) as DesignState; }
  catch { return null; }
}

/** A design run is working on the episode: it saved a turn recently and hasn't failed. */
export function isDesigningVideo(podcast: Pick<DailyPodcast, "videoDesign">, now = Date.now()) {
  const design = podcast.videoDesign;
  return !!design && !design.error && now - Date.parse(design.updatedAt) < STALE_MS;
}

/** Composition progress mapped into the episode's design stage, as `createPodcastVideo` streams it. */
function designPercent(progress: number) {
  return 10 + Math.floor(progress * 0.8);
}

/**
 * Starts designing a new composition for a saved episode in the background and returns the episode with
 * its `videoDesign` status. A run already working on it is reused. `checkPoints` refuses to start
 * without a balance; points are charged for the model's tokens when the run ends.
 */
export async function startPodcastVideoDesign(db: Database, user: string, podcast: DailyPodcast, chips: { id: string; title: string }[],
  deps: Deps & { billingEnvironment?: BillingEnvironment }, options: { language?: TranslationLanguage; style?: PodcastVideoStyle; checkPoints: boolean }): Promise<DailyPodcast> {
  if (isDesigningVideo(podcast)) return podcast;
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const model = ai.podcastVideoModelId();
  if (!model) throw new ApiError(503, "PODCAST_VIDEO_UNAVAILABLE", "Podcast videos are not available right now.");
  const job: PodcastVideoJob = { id: randomUUID(), userId: user, key: podcast.key, day: podcast.day,
    language: options.language, billingEnvironment: deps.billingEnvironment };
  if (options.checkPoints) {
    // Only checks the balance: the run outlives any hold, so its cost is charged when it ends.
    const check = await reservePodcastPoints(user, `${podcast.key}:video:${job.id}`, model, deps.billingEnvironment);
    await check?.settle(0, { check: true });
  }
  const state: DesignState = { input: podcastVideoInput(podcast, chips, options.style), chips, draft: newPodcastVideoDraft(), costUsd: 0, failures: 0, progress: 0 };
  await store.put(statePath(job), jsonObject(state));
  const now = (deps.now?.() ?? new Date()).toISOString();
  const design: PodcastVideoDesign = { id: job.id, startedAt: now, updatedAt: now, percent: designPercent(0), ...(options.language ? { language: options.language } : {}) };
  await updatePodcastDocument(db, user, podcast.key, (latest) => { latest.videoDesign = design; });
  await db.insert(backgroundJobs).values({ id: job.id, ownerId: user, episodeKey: podcast.key, createdAt: new Date(now),
    document: { id: job.id, title: podcast.title, episodeKey: podcast.key, day: podcast.day, language: options.language,
      status: "running", percent: design.percent, createdAt: now, updatedAt: now,
      logs: [{ id: "queued", at: now, message: "Queued video script design. You can close the app while it runs." }] } });
  try {
    await getPodcastVideoDesigner().start(job);
  } catch (error) {
    console.error("[podcast-video] background design could not start", error);
    await recordJobActivity(db, user, job.id, "failed", "The background job could not start. Open the podcast to try again.", { status: "failed" });
    await updatePodcastDocument(db, user, podcast.key, (latest) => { if (latest.videoDesign?.id === job.id) delete latest.videoDesign; });
    await store.delete(statePath(job));
    throw new ApiError(503, "PODCAST_VIDEO_UNAVAILABLE", "The video could not be started right now. Please try again.");
  }
  return dailyPodcastEpisode(db, user, podcast.day, podcast.key);
}

/** The episode while `job` is its current run; null once a newer run replaced it or the episode is gone. */
async function currentEpisode(db: Database, job: PodcastVideoJob) {
  const podcast = await dailyPodcastEpisode(db, job.userId, job.day, job.key).catch(() => null);
  return podcast?.videoDesign?.id === job.id ? podcast : null;
}

/**
 * One agent turn of a background run: loads the draft, lets the agent make one small change, saves it
 * and reports progress on the episode. A failed model call is counted and retried by the next turn; only
 * storage or database errors throw (the workflow retries the step).
 */
export async function runPodcastVideoDesignTurn(db: Database, job: PodcastVideoJob, deps: Deps = {}): Promise<PodcastVideoOutcome> {
  const store = deps.store ?? getObjectStore();
  if (!await currentEpisode(db, job)) {
    await recordJobActivity(db, job.userId, job.id, "replaced", "This design was replaced or its episode was removed.", { status: "failed" });
    return { status: "failed", code: "PODCAST_VIDEO_REPLACED" };
  }
  const state = await readState(store, job);
  if (!state) return { status: "failed", code: "PODCAST_VIDEO_FAILED" };
  if (podcastVideoDraftFinished(state.draft)) return state.draft.result ? { status: "accepted" } : { status: "failed", code: "PODCAST_VIDEO_FAILED" };
  const ai = deps.ai ?? await getAiProvider();
  const usage: { step: LanguageModelUsage; modelId?: string }[] = [];
  let evidence: string;
  try {
    const turn = await ai.podcastVideoTurn(state.input, state.draft, { abortSignal: AbortSignal.timeout(TURN_TIMEOUT_MS), onUsage: (step, modelId) => usage.push({ step, modelId }) });
    state.draft = turn.draft;
    state.failures = 0;
    delete state.lastError;
    evidence = turn.evidence;
  } catch (error) {
    // Keep the reminder (and a switch to the fallback model), so the retry doesn't repeat the prompt that failed.
    if (error instanceof PodcastVideoNoToolError) state.draft = error.draft;
    state.failures += 1;
    state.lastError = podcastVideoError(error);
    console.error(`[podcast-video] design turn failed ${JSON.stringify({ job: job.id, failures: state.failures,
      code: state.lastError.code, name: error instanceof Error ? error.name : "UnknownError",
      message: (error instanceof Error ? error.message : String(error)).slice(0, 1000) })}`);
    evidence = `${state.lastError.message} Attempt ${state.failures} of ${MAX_FAILED_TURNS} failed.${state.failures < MAX_FAILED_TURNS ? " Retrying…" : ""}`;
  }
  // Priced per model: a declined turn re-runs on the fallback model at its own rates.
  for (const { step, modelId } of usage) {
    const pricing = await ai.podcastVideoPricing(modelId);
    if (pricing) state.costUsd += usageCostUsd(step, pricing);
  }
  if (state.draft.result) state.progress = 90;
  else if (!state.lastError && Object.keys(state.draft.files).length > 0) {
    const recent = JSON.stringify(state.draft.messages.at(-2) ?? "").slice(-4000);
    const estimate = await estimateVideoProgress(JSON.stringify({ context: podcastVideoProgressContext(state.input), evidence, recentOutput: recent }),
      AbortSignal.timeout(4_000)).catch(() => null);
    if (estimate !== null && Number.isFinite(estimate)) state.progress = Math.max(state.progress, Math.min(90, Math.round(estimate)));
  }
  await store.put(statePath(job), jsonObject(state));
  const now = (deps.now?.() ?? new Date()).toISOString();
  await updatePodcastDocument(db, job.userId, job.key, (latest) => {
    if (latest.videoDesign?.id !== job.id) return;
    latest.videoDesign = { ...latest.videoDesign, updatedAt: now, percent: designPercent(state.progress) };
  });
  await recordJobActivity(db, job.userId, job.id, `turn:${state.draft.turns}:failure:${state.failures}`,
    evidence, { percent: designPercent(state.progress), error: state.lastError });
  if (state.draft.result) return { status: "accepted" };
  if (state.failures >= MAX_FAILED_TURNS || podcastVideoDraftFinished(state.draft)) {
    const error = state.lastError ?? { code: "PODCAST_VIDEO_FAILED", message: "The video agent reached its turn or validation limit without a valid script. Please retry video design." };
    return { status: "failed", code: error.code, error };
  }
  return { status: "running" };
}

/**
 * Ends a background run: saves an accepted composition in place of the previous one (its renders become
 * stale), charges the run's tokens and clears the status, or records the failure for the app to show.
 * Returns whether a composition was saved and the run continues to translate it for `job.language`.
 */
export async function finishPodcastVideoDesign(db: Database, job: PodcastVideoJob, outcome: PodcastVideoOutcome, deps: Deps = {}): Promise<boolean> {
  const store = deps.store ?? getObjectStore();
  const savedEpisode = await dailyPodcastEpisode(db, job.userId, job.day, job.key).catch(() => null);
  // A finish step can resume after saving the composition but before saving its job status.
  if (savedEpisode?.video?.id === job.id) {
    const translating = savedEpisode.videoDesign?.id === job.id && !!job.language;
    const videoId = job.language ? savedEpisode.translations?.[job.language]?.video?.id : savedEpisode.video.id;
    await recordJobActivity(db, job.userId, job.id, translating ? "translating" : "ready",
      translating ? "Translating video labels…" : "Composition ready. HD video will render in the cloud.",
      { status: translating ? "running" : "ready", percent: translating ? 92 : 100, videoId });
    await store.delete(statePath(job));
    await queueDefaultPodcastRender(db, job.userId, job.day, job.key);
    return translating;
  }
  const podcast = savedEpisode?.videoDesign?.id === job.id ? savedEpisode : null;
  const state = await readState(store, job);
  if (!podcast || !state) {
    await recordJobActivity(db, job.userId, job.id, "failed", "Design could not continue. Open the podcast to retry.", { status: "failed" });
    await store.delete(statePath(job));
    return false;
  }
  const ai = deps.ai ?? await getAiProvider();
  const model = ai.podcastVideoModelId() ?? "video";
  const result = outcome.status === "accepted" ? state.draft.result : null;
  // Settling is idempotent, so a retried finish never charges twice. A failed design is free.
  const charge = await reservePodcastPoints(job.userId, `${job.key}:video:${job.id}:charge`, model, job.billingEnvironment).catch((error) => {
    console.error("[podcast-video] could not charge the design", { job: job.id, error });
    return null;
  });
  await charge?.settle(result ? Math.max(1, pointsForCost(state.costUsd)) : 0, { videoCostUsd: state.costUsd, turns: state.draft.turns, failed: !result });
  if (!result) {
    const code = outcome.status === "failed" ? outcome.code : "PODCAST_VIDEO_FAILED";
    const error = (outcome.status === "failed" ? outcome.error : undefined) ?? state.lastError
      ?? { code, message: "The video could not be designed. Open the podcast to retry." };
    await recordJobActivity(db, job.userId, job.id, "failed", error.message, { status: "failed", error });
    await updatePodcastDocument(db, job.userId, job.key, (latest) => {
      if (latest.videoDesign?.id !== job.id) return;
      latest.videoDesign = { ...latest.videoDesign, updatedAt: new Date().toISOString(),
        error };
    });
    await store.delete(statePath(job));
    return false;
  }
  const source = { id: job.id, model, createdAt: new Date().toISOString(), fps: PODCAST_VIDEO_FPS,
    width: PODCAST_VIDEO_WIDTH, height: PODCAST_VIDEO_HEIGHT, chips: state.chips,
    files: { ...result, ...PODCAST_VIDEO_SCAFFOLD, [PODCAST_VIDEO_PHRASES]: JSON.stringify(podcastPhraseWindows(state.input.segments)) } };
  const video = await storePodcastVideo(store, `${dayKey(job.userId, job.day)}/${job.key}`, source);
  const translating = !!job.language && !!podcast.translations?.[job.language];
  const stale: string[] = [];
  const retired: PodcastVideoSummary[] = [];
  await updatePodcastDocument(db, job.userId, job.key, (latest) => {
    if (latest.videoDesign?.id !== job.id) return;
    if (latest.video) retired.push(latest.video);
    if (latest.video?.published) stale.push(latest.video.published.videoId);
    latest.video = video;
    // Translated videos showed the replaced composition: each translation can make a new one from this.
    for (const other of Object.values(latest.translations ?? {})) {
      if (other.video) retired.push(other.video);
      if (other.video?.published) stale.push(other.video.published.videoId);
      delete other.video;
    }
    if (latest.videoDesign?.id !== job.id) return;
    if (translating) latest.videoDesign = { ...latest.videoDesign, updatedAt: new Date().toISOString(), percent: 92 };
    else delete latest.videoDesign;
  });
  // Old renders show the replaced composition; share links fall back to audio until the new one is published.
  for (const videoId of stale) await store.delete(renderKey(job.userId, job.day, job.key, videoId));
  for (const video of retired) await retirePodcastRenders(store, job.userId, job.day, job.key, video);
  await store.delete(statePath(job));
  await recordJobActivity(db, job.userId, job.id, translating ? "translating" : "ready",
    translating ? "Translating video labels…" : "Composition ready. HD video will render in the cloud.",
    { status: translating ? "running" : "ready", percent: translating ? 92 : 100, videoId: translating ? undefined : source.id });
  await queueDefaultPodcastRender(db, job.userId, job.day, job.key);
  return translating;
}

/** Gives the requested translation the new composition with translated labels, then clears the status. */
export async function translatePodcastVideoDesign(db: Database, job: PodcastVideoJob, deps: Deps = {}): Promise<void> {
  if (!job.language) return;
  const podcast = await currentEpisode(db, job);
  if (!podcast) {
    // Recover if a translated composition was committed before the job log was saved.
    const saved = await dailyPodcastEpisode(db, job.userId, job.day, job.key).catch(() => null);
    const videoId = saved?.video?.id === job.id ? saved.translations?.[job.language]?.video?.id : undefined;
    if (videoId) await recordJobActivity(db, job.userId, job.id, "ready",
      "Composition ready. HD video will render in the cloud.", { status: "ready", percent: 100, videoId });
    return;
  }
  const clear = async (error?: PodcastVideoDesign["error"]) => {
    const saved = await updatePodcastDocument(db, job.userId, job.key, (latest) => {
      if (latest.videoDesign?.id !== job.id) return;
      if (error) latest.videoDesign = { ...latest.videoDesign, updatedAt: new Date().toISOString(), error };
      else delete latest.videoDesign;
    });
    await recordJobActivity(db, job.userId, job.id, error ? "failed" : "ready",
      error?.message ?? "Composition ready. HD video will render in the cloud.",
      { status: error ? "failed" : "ready", percent: error ? 92 : 100, videoId: job.language ? saved.translations?.[job.language]?.video?.id : saved.video?.id });
  };
  const translation = podcast.translations?.[job.language];
  if (!translation) return void await clear();
  const ai = deps.ai ?? await getAiProvider();
  const charge = await reservePodcastPoints(job.userId, `${job.key}:video:${job.language}:${job.id}`, ai.podcastModelId(), job.billingEnvironment).catch(() => null);
  try {
    const result = await translateVideo(ai, deps.store ?? getObjectStore(), db, job.userId, podcast, job.language, translation, () => {});
    await charge?.settle(Math.max(1, pointsForCost(result.costUsd)), { translationCostUsd: result.costUsd });
    await clear();
  } catch (error) {
    await charge?.settle(0, { failed: true });
    console.error("[podcast-video] translating the new composition failed", error);
    await clear({ code: "PODCAST_VIDEO_FAILED", message: "The video was designed, but its labels could not be translated. Please try again." });
  }
}

/**
 * Follows a background run until it ends, reporting its progress, for clients that stream the design.
 * Returns the episode then, or as it is when `signal` fires first (the run continues).
 */
export async function waitForPodcastVideoDesign(db: Database, user: string, day: PodcastDay, key: string, id: string,
  report: (stage: PodcastProgress["stage"], percent: number) => void, signal: AbortSignal, intervalMs = 2_000): Promise<DailyPodcast> {
  for (;;) {
    const podcast = await dailyPodcastEpisode(db, user, day, key);
    const design = podcast.videoDesign;
    if (design?.id !== id) {
      report("complete", 100);
      return podcast;
    }
    if (design.error) throw new ApiError(502, design.error.code, design.error.message);
    report("video-design", design.percent);
    if (signal.aborted) return podcast;
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

/** Runs a job's steps in this process, like the workflow does. For tests and local tools. */
export async function runPodcastVideoDesignJob(db: Database, job: PodcastVideoJob, deps: Deps = {}): Promise<PodcastVideoOutcome> {
  let outcome: PodcastVideoOutcome = { status: "running" };
  for (let turn = 0; turn < PODCAST_VIDEO_DESIGN_TURNS && outcome.status === "running"; turn += 1) {
    outcome = await runPodcastVideoDesignTurn(db, job, deps);
  }
  if (outcome.status === "running") outcome = { status: "failed", code: "PODCAST_VIDEO_FAILED" };
  if (await finishPodcastVideoDesign(db, job, outcome, deps)) await translatePodcastVideoDesign(db, job, deps);
  await notifyBackgroundJob(db, job.userId, job.id);
  return outcome;
}
