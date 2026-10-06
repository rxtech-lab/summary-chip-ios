import { and, asc, eq, inArray, isNull, lte, or, sql } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/provider";
import { tripChanges, type TripChangeInput } from "@/lib/ai/trip-change-agent";
import type { TripDocument } from "@/lib/contracts/trip";
import type { Database } from "@/lib/db/client";
import { pushDevices, summaries, summaryViews, tripNotificationBatches as batches, tripNotificationDeliveries as deliveries } from "@/lib/db/schema";
import { apnsConfigured, sendPush } from "@/lib/notifications/apns";
import { getTripNotifier } from "@/lib/trips/notifier";
import { isDeadToken, tripUpdatedPayload } from "./notifications";
import { canViewerRead, readableByViewer } from "./share-access";

export const TRIP_NOTIFICATION_DELAY_MS = 5 * 60_000;
const LEASE_MS = 10 * 60_000;

/** Must immediately follow the revision CAS in the same SQLite batch: changes() fences it. */
export function queueTripChangesStatement(db: Database, tripId: string, revision: number, before: TripDocument, after: TripDocument, now: Date) {
  return db.run(sql`
    INSERT INTO trip_notification_batches (id, trip_id, revision, before_document, after_document, due_at)
    SELECT ${crypto.randomUUID()}, ${tripId}, ${revision}, ${JSON.stringify(before)}, ${JSON.stringify(after)}, ${now.getTime() + TRIP_NOTIFICATION_DELAY_MS}
    WHERE changes() > 0
    ON CONFLICT (trip_id) WHERE status = 'pending' DO UPDATE SET
      revision = excluded.revision, after_document = excluded.after_document,
      due_at = excluded.due_at, runner_id = NULL, lease_until = NULL
    RETURNING id
  `);
}

/** Persistence already succeeded; a failed start is recovered by the notification cron. */
export async function startTripNotification(batchId: string): Promise<void> {
  await getTripNotifier().start(batchId);
}

type Plan =
  | { status: "done" }
  | { status: "wait"; nextAt: number }
  | { status: "summarize"; revision: number; input: TripChangeInput }
  | { status: "deliver" };

/** Competing runs use a lease; edits invalidate an in-progress summary and extend the delay. */
export async function planTripNotification(db: Database, batchId: string, runnerId: string, now = new Date()): Promise<Plan> {
  const [row] = await db.select().from(batches).where(eq(batches.id, batchId));
  if (!row) return { status: "done" };
  if (row.status === "pending" && row.dueAt > now) return { status: "wait", nextAt: row.dueAt.getTime() };
  // A duplicate run can stop: the durable owner continues, or the cron recovers its expired lease.
  if (row.runnerId !== runnerId && row.leaseUntil && row.leaseUntil > now) return { status: "done" };
  const claimed = await db.update(batches).set({ runnerId, leaseUntil: new Date(now.getTime() + LEASE_MS) })
    .where(and(eq(batches.id, batchId), eq(batches.revision, row.revision), eq(batches.status, row.status),
      or(eq(batches.runnerId, runnerId), isNull(batches.leaseUntil), lte(batches.leaseUntil, now))));
  if (!claimed.rowsAffected) return { status: "wait", nextAt: now.getTime() + 1000 };
  if (row.status === "ready") return { status: "deliver" };
  const changes = tripChanges(row.beforeDocument, row.afterDocument);
  if (!changes.length) {
    await db.delete(batches).where(and(eq(batches.id, batchId), eq(batches.revision, row.revision), eq(batches.runnerId, runnerId)));
    return { status: "done" };
  }
  const [summary] = await db.select({ language: summaries.language }).from(summaries).where(eq(summaries.id, row.tripId));
  if (!summary) return { status: "done" };
  return { status: "summarize", revision: row.revision, input: { language: summary.language, changes } };
}

export async function writeTripChangeSummary(input: TripChangeInput): Promise<string> {
  return (await getAiProvider()).summarizeTripChanges(input);
}

/** Freeze only the revision the agent actually described. A save during generation makes it stale. */
export async function publishTripNotification(db: Database, batchId: string, runnerId: string, revision: number, body: string): Promise<boolean> {
  const result = await db.update(batches).set({ status: "ready", changeSummary: body })
    .where(and(eq(batches.id, batchId), eq(batches.status, "pending"), eq(batches.revision, revision), eq(batches.runnerId, runnerId)));
  return result.rowsAffected > 0;
}

/** One bounded fan-out step. Accepted installations are recorded before another retry can send. */
export async function deliverTripNotification(db: Database, batchId: string, runnerId: string, now = new Date()): Promise<boolean> {
  const [batch] = await db.select().from(batches).where(and(eq(batches.id, batchId), eq(batches.status, "ready"), eq(batches.runnerId, runnerId)));
  if (!batch) return true;
  if (!apnsConfigured()) {
    await db.delete(batches).where(and(eq(batches.id, batchId), eq(batches.runnerId, runnerId)));
    return true;
  }
  const [summary] = await db.select().from(summaries).where(eq(summaries.id, batch.tripId));
  if (!summary) return true;
  // Viewers who can still open the trip: through its public link, or the share link they opened it with.
  const viewers = await db.select({ userId: summaryViews.userId }).from(summaryViews)
    .innerJoin(summaries, eq(summaries.id, summaryViews.summaryId))
    .where(and(eq(summaryViews.summaryId, batch.tripId), readableByViewer(summaryViews.userId, now)));
  const recipients = new Set([summary.ownerId, ...viewers.map((viewer) => viewer.userId)]);
  const sent = await db.select().from(deliveries).where(eq(deliveries.batchId, batchId));
  const delivered = new Set(sent.map((entry) => `${entry.installationId}:${entry.userId}`));
  const devices = (await db.select().from(pushDevices).where(inArray(pushDevices.ownerId, [...recipients])))
    .filter((device) => !delivered.has(`${device.installationId}:${device.ownerId}`));
  for (const device of devices.slice(0, 20)) {
    // Sharing and registrations may change while previous devices are being sent.
    const [current] = await db.select().from(summaries).where(eq(summaries.id, batch.tripId));
    const [lease] = await db.select({ runnerId: batches.runnerId }).from(batches).where(eq(batches.id, batchId));
    if (!current || lease?.runnerId !== runnerId) return true;
    if (device.ownerId !== current.ownerId) {
      const [view] = await db.select().from(summaryViews).where(and(eq(summaryViews.summaryId, batch.tripId), eq(summaryViews.userId, device.ownerId)));
      if (!view || !await canViewerRead(db, current, device.ownerId)) continue;
    }
    const [registered] = await db.select().from(pushDevices).where(and(eq(pushDevices.installationId, device.installationId), eq(pushDevices.ownerId, device.ownerId), eq(pushDevices.token, device.token)));
    if (!registered) continue;
    const result = await sendPush(device,
      tripUpdatedPayload(device.ownerId, batch.tripId, batch.afterDocument.title, batch.changeSummary!, current.language),
      { collapseId: `trip-update:${batchId}` });
    if (isDeadToken(result)) {
      await db.delete(pushDevices).where(and(eq(pushDevices.installationId, device.installationId), eq(pushDevices.ownerId, device.ownerId), eq(pushDevices.token, device.token), eq(pushDevices.updatedAt, device.updatedAt)));
    } else if (result.status !== 200) {
      // Throw so Workflow retries. No payload, token or source content in errors.
      throw new Error(`Trip notification rejected by APNs (${result.status})`);
    }
    await db.insert(deliveries).values({ batchId, installationId: device.installationId, userId: device.ownerId }).onConflictDoNothing();
  }
  if (devices.length > 20) return false;
  // Delete snapshots and delivery receipts after fan-out; late/duplicate runs now stop.
  await db.delete(batches).where(and(eq(batches.id, batchId), eq(batches.runnerId, runnerId)));
  return true;
}

/** Safety net for an interrupted workflow start or a run that exhausted its retries. */
export async function resumeTripNotifications(db: Database, now = new Date()): Promise<{ restarted: number }> {
  const rows = await db.select({ id: batches.id }).from(batches)
    .where(and(lte(batches.dueAt, now), or(isNull(batches.leaseUntil), lte(batches.leaseUntil, now))))
    .orderBy(asc(batches.dueAt)).limit(100);
  let restarted = 0;
  for (const row of rows) {
    try { await startTripNotification(row.id); restarted += 1; }
    catch { console.warn("[trip-notifications] workflow start failed"); }
  }
  return { restarted };
}
