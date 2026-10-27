import { randomUUID } from "node:crypto";
import { and, desc, eq, isNull, lte } from "drizzle-orm";
import { z } from "zod";
import type { Database } from "@/lib/db/client";
import { dailyRecapRuns as runs, dailyRecapSchedules as schedules, podcastEpisodes, users } from "@/lib/db/schema";
import { TRANSLATION_LANGUAGES } from "@/lib/contracts/api";
import type { PodcastDay } from "@/lib/contracts/daily-podcast";
import type { BillingEnvironment } from "@/lib/subscription/config";
import type { ServiceDeps } from "./summaries";
import { addDays, isTimeZone, localParts, zonedTime } from "@/lib/weather/schedule";
import { createDailyPodcast, dailyPodcastChips } from "./daily-podcast";

export const dailyRecapSettingsSchema = z.object({
  enabled: z.boolean(),
  timeZone: z.string().max(100).refine(isTimeZone, "Choose a valid time zone"),
  language: z.enum(TRANSLATION_LANGUAGES),
  hour: z.number().int().min(0).max(23).default(7),
}).strict();

export function nextRecapAt(now: Date, zone: string, hour: number): Date {
  const local = localParts(now.getTime(), zone);
  const today = zonedTime(local.date, hour * 60, zone);
  return new Date(today > now.getTime() ? today : zonedTime(addDays(local.date, 1), hour * 60, zone));
}
export function recapDay(now: Date, zone: string): { date: string; day: PodcastDay } {
  const today = localParts(now.getTime(), zone).date;
  const date = addDays(today, -1);
  return { date, day: { start: new Date(zonedTime(date, 0, zone)).toISOString(), end: new Date(zonedTime(today, 0, zone)).toISOString() } };
}

export async function dailyRecapSettings(db: Database, ownerId: string) {
  const [settings] = await db.select().from(schedules).where(eq(schedules.ownerId, ownerId));
  const [last] = await db.select().from(runs).where(eq(runs.ownerId, ownerId)).orderBy(desc(runs.createdAt)).limit(1);
  let status = last?.status;
  if (last?.episodeKey && status === "rendering") {
    const [episode] = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.key, last.episodeKey), eq(podcastEpisodes.ownerId, ownerId), eq(podcastEpisodes.deleted, false)));
    const render = episode?.document.video?.renders?.["1080"];
    status = render?.status === "ready" ? "ready" : render?.status === "failed" || episode?.document.videoDesign?.error ? "failed" : "rendering";
  }
  const interrupted = last && (status === "queued" || status === "generating") && Date.now() - last.createdAt.getTime() > 15 * 60_000;
  if (interrupted) status = "failed";
  return { enabled: settings?.enabled ?? false, timeZone: settings?.timeZone ?? "UTC", language: settings?.language ?? "en",
    hour: settings?.hour ?? 7, nextAt: settings?.enabled ? settings.nextAt.toISOString() : null,
    lastRun: last ? { date: last.date, status, episodeKey: last.episodeKey, error: interrupted ? "The run was interrupted. Open the day’s podcast to retry manually." : last.error } : null };
}
export async function saveDailyRecapSettings(db: Database, ownerId: string, input: z.infer<typeof dailyRecapSettingsSchema>, environment?: BillingEnvironment, now = new Date()) {
  const values = { ...input, billingEnvironment: environment ?? null, nextAt: nextRecapAt(now, input.timeZone, input.hour) };
  await db.insert(schedules).values({ ownerId, ...values }).onConflictDoUpdate({ target: schedules.ownerId, set: values });
  return dailyRecapSettings(db, ownerId);
}

export interface DailyRecapJob { id: string; ownerId: string; day: PodcastDay; language: typeof TRANSLATION_LANGUAGES[number]; billingEnvironment?: BillingEnvironment }
export interface DailyRecapStarter { start(job: DailyRecapJob): Promise<void> }
let override: DailyRecapStarter | undefined;
export function setDailyRecapStarterForTests(value?: DailyRecapStarter) { override = value; }
function starter(): DailyRecapStarter {
  return override ?? { async start(job) {
    const [{ start }, { generateDailyRecap }] = await Promise.all([import("workflow/api"), import("@/workflows/generate-daily-recap")]);
    await start(generateDailyRecap, [job]);
  } };
}

/** Claim once before dispatch: ambiguous starts and provider failures never spend again automatically. */
export async function dispatchDailyRecaps(db: Database, now = new Date()) {
  const due = await db.select({ schedule: schedules }).from(schedules).innerJoin(users, eq(users.id, schedules.ownerId))
    .where(and(eq(schedules.enabled, true), lte(schedules.nextAt, now), isNull(users.deletionScheduledAt)))
    .orderBy(schedules.nextAt).limit(20);
  let started = 0;
  for (const { schedule } of due) {
    const { date, day } = recapDay(now, schedule.timeZone);
    const id = randomUUID();
    const claimed = await db.update(schedules).set({ nextAt: nextRecapAt(now, schedule.timeZone, schedule.hour) })
      .where(and(eq(schedules.ownerId, schedule.ownerId), eq(schedules.enabled, true), eq(schedules.nextAt, schedule.nextAt)));
    if (!claimed.rowsAffected) continue;
    const inserted = await db.insert(runs).values({ id, ownerId: schedule.ownerId, date, status: "queued", createdAt: now }).onConflictDoNothing();
    if (!inserted.rowsAffected) continue;
    try {
      await starter().start({ id, ownerId: schedule.ownerId, day, language: schedule.language as DailyRecapJob["language"], billingEnvironment: schedule.billingEnvironment ?? undefined });
      started++;
    } catch {
      await db.update(runs).set({ status: "failed", error: "The background run could not be confirmed. Open the day's podcast to generate it manually." })
        .where(and(eq(runs.id, id), eq(runs.status, "queued")));
    }
  }
  return { started };
}

/** Non-retrying generation: a crash must not duplicate AI charges. */
export async function runDailyRecap(db: Database, job: DailyRecapJob, deps: ServiceDeps = {}) {
  const claimed = await db.update(runs).set({ status: "generating" }).where(and(eq(runs.id, job.id), eq(runs.ownerId, job.ownerId), eq(runs.status, "queued")));
  if (!claimed.rowsAffected) return;
  try {
    const [schedule] = await db.select().from(schedules).innerJoin(users, eq(users.id, schedules.ownerId))
      .where(and(eq(schedules.ownerId, job.ownerId), eq(schedules.enabled, true), isNull(users.deletionScheduledAt)));
    if (!schedule || !(await dailyPodcastChips(db, job.ownerId, job.day)).length) {
      await db.update(runs).set({ status: "skipped" }).where(eq(runs.id, job.id));
      return;
    }
    const podcast = await createDailyPodcast(db, job.ownerId, { day: job.day, language: job.language, regenerate: true, library: false, includeVideo: true, recap: true },
      { ...deps, billingEnvironment: job.billingEnvironment });
    await db.update(runs).set({ status: podcast.videoDesign || podcast.video ? "rendering" : "failed", episodeKey: podcast.key,
      error: podcast.videoDesign || podcast.video ? null : "Audio is saved, but video design could not start. Open the episode to retry." }).where(eq(runs.id, job.id));
  } catch {
    await db.update(runs).set({ status: "failed", error: "Recap generation failed. Check your points balance and open the day's podcast to retry manually." }).where(eq(runs.id, job.id));
  }
}
