import { randomUUID } from "node:crypto";
import type { Database } from "@/lib/db/client";
import { backgroundJobs } from "@/lib/db/schema";
import type { DailyPodcast, PodcastDay, PodcastVideoRender, PodcastVideoSummary } from "@/lib/contracts/daily-podcast";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { getPodcastRenderStarter } from "@/lib/podcast-video/render-workflow";
import { dailyPodcastEpisode, dayKey, isTranslation, podcastInLanguage, translationMissing, updatePodcastDocument } from "./daily-podcast";
import { recordJobActivity } from "./background-jobs";

export interface PodcastRenderJob {
  id: string; userId: string; key: string; day: PodcastDay; videoId: string; language?: string; resolution: 720 | 1080;
}
const staleMs = 60 * 60_000;
function videoOf(podcast: DailyPodcast, language?: string) {
  if (!isTranslation(podcast, language)) return podcast.video;
  if (!podcast.translations?.[language!]) throw translationMissing();
  return podcast.translations[language!].video;
}
export function podcastRenderKey(job: PodcastRenderJob) {
  return `${dayKey(job.userId, job.day)}/${job.key}/video/${job.videoId}-${job.id}-${job.resolution}p.mp4`;
}
export async function currentPodcastRender(db: Database, job: PodcastRenderJob) {
  const podcast = await dailyPodcastEpisode(db, job.userId, job.day, job.key);
  const video = videoOf(podcast, job.language);
  if (video?.id !== job.videoId || video.renders?.[job.resolution]?.id !== job.id)
    throw new ApiError(409, "PODCAST_VIDEO_CHANGED", "The composition was replaced. Start a new render.");
  return podcastInLanguage(podcast, job.language);
}

/** Claims the render and job in one transaction: parallel callers reuse the same work. */
export async function startPodcastRender(db: Database, userId: string, day: PodcastDay, key: string, resolution: 720 | 1080 = 1080, language?: string) {
  await dailyPodcastEpisode(db, userId, day, key);
  let job: PodcastRenderJob | undefined;
  await renderTransaction(db, async tx => {
    job = undefined;
    await updatePodcastDocument(tx, userId, key, latest => {
      const video = videoOf(latest, language);
      if (!video) throw new ApiError(409, "PODCAST_VIDEO_MISSING", "Wait for video design to finish before rendering.");
      const previous = video.renders?.[resolution];
      if (previous?.status === "ready" || previous?.status === "running" && Date.now() - Date.parse(previous.updatedAt) < staleMs) return;
      const at = new Date().toISOString();
      job = { id: randomUUID(), userId, key, day, videoId: video.id, resolution, language };
      video.renders = { ...video.renders, [resolution]: { id: job.id, status: "running", resolution, updatedAt: at } };
    });
    const claimed = job as PodcastRenderJob | undefined;
    if (claimed) {
      const at = new Date().toISOString();
      await tx.insert(backgroundJobs).values({ id: claimed.id, ownerId: userId, episodeKey: key, createdAt: new Date(at),
        document: { id: claimed.id, title: `Render ${resolution}p video`, kind: "render", episodeKey: key, day, language,
          status: "running", videoId: claimed.videoId, percent: 0, createdAt: at, updatedAt: at,
          logs: [{ id: "queued", at, message: "Queued cloud video render. You can close the app." }] } });
    }
  });
  if (job) {
    try { await getPodcastRenderStarter().start(job); }
    catch (error) {
      await finishPodcastRender(db, job, undefined, podcastRenderError(error));
      console.error("[podcast-render] workflow could not start", error);
      throw new ApiError(503, "PODCAST_RENDER_UNAVAILABLE", "Cloud rendering could not start. Please try again.");
    }
  }
  return podcastRenderStatus(db, userId, day, key, resolution, language);
}

/** Read-only status. Only an authenticated owner receives a short-lived object URL. */
export async function podcastRenderStatus(db: Database, userId: string, day: PodcastDay, key: string, resolution: 720 | 1080 = 1080, language?: string) {
  const podcast = podcastInLanguage(await dailyPodcastEpisode(db, userId, day, key), language);
  const render = podcast.video?.renders?.[resolution];
  const job = render && { id: render.id, userId, key, day, resolution, language, videoId: podcast.video!.id };
  const visible = render?.status === "running" && Date.now() - Date.parse(render.updatedAt) >= staleMs
    ? { ...render, status: "failed" as const, error: { code: "PODCAST_RENDER_TIMEOUT", message: "The render stopped. Please retry." } } : render;
  return { videoId: podcast.video?.id, render: visible ?? null,
    ...(render?.status === "ready" && job ? { downloadUrl: (await getObjectStore().signedGet(podcastRenderKey(job), { filename: `podcast-${resolution}p.mp4`, expiresInSeconds: 600 })).url } : {}) };
}

export function podcastRenderError(failure?: unknown) {
  // Only known application codes may cross into owner-visible job history.
  const code = (failure as { code?: string } | undefined)?.code;
  if (code === "PODCAST_RENDER_UNAVAILABLE") return { code, message: "The cloud video renderer is unavailable. Check the server's Vercel Sandbox credentials and renderer snapshot configuration." };
  if (code === "PODCAST_VIDEO_CHANGED") return { code, message: "The composition was replaced. Start a new render." };
  return { code: "PODCAST_RENDER_FAILED", message: "Cloud video rendering failed. Please retry from the podcast." };
}

export async function finishPodcastRender(db: Database, job: PodcastRenderJob, byteSize: number | undefined, failure?: { code: string }) {
  const error = podcastRenderError(failure);
  let accepted = false;
  try {
    await renderTransaction(db, async tx => {
      accepted = false;
      await updatePodcastDocument(tx, job.userId, job.key, latest => {
        const video = videoOf(latest, job.language);
        if (video?.id !== job.videoId || video.renders?.[job.resolution]?.id !== job.id) return;
        accepted = true;
        const render: PodcastVideoRender = { id: job.id, resolution: job.resolution, updatedAt: new Date().toISOString(),
          status: byteSize ? "ready" : "failed", ...(byteSize ? { byteSize } : { error }) };
        video.renders[job.resolution] = render;
      });
    });
  } catch (failure) {
    if (!(failure instanceof ApiError && failure.status === 404)) throw failure;
  }
  await recordJobActivity(db, job.userId, job.id, "finished", accepted && byteSize ? "Video ready in R2. Open the podcast to watch or download."
    : error.message,
    { status: accepted && byteSize ? "ready" : "failed", percent: 100, ...(!accepted || !byteSize ? { error } : {}) });
  if (!accepted || !byteSize) await getObjectStore().delete(podcastRenderKey(job));
}

/** Called after saving a new composition. Audio and source remain usable if infrastructure is unavailable. */
export async function queueDefaultPodcastRender(db: Database, user: string, day: PodcastDay, key: string, language?: string) {
  try { await startPodcastRender(db, user, day, key, 1080, language); }
  catch (error) { console.error("[podcast-render] automatic render could not start", error); }
}

const writers = new WeakMap<Database, Promise<unknown>>();

/** SQLite allows one writer at a time. Retry only lock contention, never provider work. */
async function renderTransaction<T>(db: Database, action: Parameters<Database["transaction"]>[0]): Promise<T> {
  const previous = writers.get(db) ?? Promise.resolve();
  const run = previous.catch(() => {}).then(async () => {
    for (let attempt = 0; ; attempt++) {
      try { return await db.transaction(action) as T; }
      catch (error) {
        const failure = error as { code?: string; cause?: { code?: string } };
        if (attempt >= 3 || ![failure.code, failure.cause?.code].includes("SQLITE_BUSY")) throw error;
        await new Promise(resolve => setTimeout(resolve, 25 * (attempt + 1)));
      }
    }
  });
  writers.set(db, run);
  return run;
}

/** Removes exports of a retired composition; running jobs are fenced and clean their own output. */
export async function retirePodcastRenders(store: ObjectStore, userId: string, day: PodcastDay, key: string, video?: PodcastVideoSummary) {
  if (!video) return;
  await Promise.all(Object.values(video.renders ?? {}).map(render => render && store.delete(podcastRenderKey({
    id: render.id, videoId: video.id, resolution: render.resolution, userId, day, key,
  }))));
}
