import { and, desc, eq, isNull, lt, or } from "drizzle-orm";
import type { BackgroundJob } from "@/lib/contracts/background-jobs";
import type { Database } from "@/lib/db/client";
import { backgroundJobs, podcastEpisodes } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { deliver } from "./notifications";

const staleMs = 20 * 60_000;
/** A stopped workflow remains inspectable and offers an explicit retry in the podcast. */
function visibleJob(job: BackgroundJob): BackgroundJob {
  if (job.status === "failed" && !job.error) return { ...job, error: { code: "PODCAST_VIDEO_FAILED",
    message: job.logs.at(-1)?.message ?? "Video design failed. Open the podcast to retry." } };
  if (job.status !== "running" || Date.now() - Date.parse(job.updatedAt) < staleMs) return job;
  return { ...job, status: "failed", error: { code: "PODCAST_VIDEO_STALLED", message: "No activity for 20 minutes. The workflow may have stopped. Open the podcast to retry video design." }, logs: [...job.logs, { id: "stalled", at: job.updatedAt,
    message: "No recent activity. Open the podcast to retry video design." }] };
}

export async function backgroundJob(db: Database, ownerId: string, id: string): Promise<BackgroundJob> {
  const [row] = await db.select({ document: backgroundJobs.document }).from(backgroundJobs)
    .innerJoin(podcastEpisodes, eq(backgroundJobs.episodeKey, podcastEpisodes.key))
    .where(and(eq(backgroundJobs.id, id), eq(backgroundJobs.ownerId, ownerId), eq(podcastEpisodes.deleted, false)));
  if (!row) throw new ApiError(404, "NOT_FOUND", "Background job not found.");
  return visibleJob(row.document);
}

/** Removes history only; the episode and its generation workflow remain intact. */
export async function deleteBackgroundJob(db: Database, ownerId: string, id: string) {
  const removed = await db.delete(backgroundJobs)
    .where(and(eq(backgroundJobs.id, id), eq(backgroundJobs.ownerId, ownerId))).returning({ id: backgroundJobs.id });
  if (!removed.length) throw new ApiError(404, "NOT_FOUND", "Background job not found.");
}

export async function listBackgroundJobs(db: Database, ownerId: string, cursor?: string) {
  const [after] = cursor ? await db.select().from(backgroundJobs)
    .where(and(eq(backgroundJobs.id, cursor), eq(backgroundJobs.ownerId, ownerId))) : [];
  if (cursor && !after) throw new ApiError(400, "INVALID_CURSOR", "Invalid job cursor.");
  const rows = await db.select({ id: backgroundJobs.id, document: backgroundJobs.document }).from(backgroundJobs)
    .innerJoin(podcastEpisodes, eq(backgroundJobs.episodeKey, podcastEpisodes.key))
    .where(and(eq(backgroundJobs.ownerId, ownerId), eq(podcastEpisodes.deleted, false), after
    ? or(lt(backgroundJobs.createdAt, after.createdAt), and(eq(backgroundJobs.createdAt, after.createdAt), lt(backgroundJobs.id, after.id))) : undefined))
    .orderBy(desc(backgroundJobs.createdAt), desc(backgroundJobs.id)).limit(51);
  return { items: rows.slice(0, 50).map(({ document }) => visibleJob(document)), nextCursor: rows.length > 50 ? rows[49].id : null };
}

/** One writer per workflow; stable event ids prevent duplicated logs on replay. */
export async function recordJobActivity(db: Database, ownerId: string, id: string, event: string,
  message: string, patch: Partial<Pick<BackgroundJob, "status" | "percent" | "videoId" | "error">> = {}) {
  const [row] = await db.select().from(backgroundJobs).where(and(eq(backgroundJobs.id, id), eq(backgroundJobs.ownerId, ownerId)));
  if (!row || row.document.status !== "running") return;
  const at = new Date().toISOString();
  const logs = row.document.logs.filter((entry) => entry.id !== event);
  logs.push({ id: event, at, message: message.slice(0, 1000) });
  if (patch.status === "failed" && !patch.error) patch = { ...patch, error: { code: "PODCAST_VIDEO_FAILED", message: message.slice(0, 1000) } };
  if (patch.status === "ready") patch = { ...patch, error: undefined };
  await db.update(backgroundJobs).set({ document: { ...row.document, ...patch, updatedAt: at, logs: logs.slice(-200) } })
    .where(and(eq(backgroundJobs.id, id), eq(backgroundJobs.ownerId, ownerId)));
}

/** A separate durable workflow step. Claim before sending, like paper notifications (at most once). */
export async function notifyBackgroundJob(db: Database, ownerId: string, id: string) {
  const job = await backgroundJob(db, ownerId, id).catch(() => null);
  if (!job || job.status === "running") return;
  const claimed = await db.update(backgroundJobs).set({ notifiedAt: new Date() })
    .where(and(eq(backgroundJobs.id, id), eq(backgroundJobs.ownerId, ownerId), isNull(backgroundJobs.notifiedAt)));
  if (!claimed.rowsAffected) return;
  await deliver(db, ownerId, {
    aps: { alert: {
      title: job.status === "ready" ? (job.kind === "render" ? "Video ready" : "Video script ready") : "Video design needs attention",
      body: job.status === "ready" ? (job.kind === "render" ? "Your HD video is ready. Open the podcast to watch or download." : "Your composition is ready. HD video rendering continues in the cloud.")
        : "Open this job to view its log, then open the podcast to retry video design.",
    }, sound: "default" },
    userId: ownerId, backgroundJobId: id,
  }, { collapseId: `video-job:${id}` });
}
