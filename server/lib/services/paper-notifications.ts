import { and, asc, eq, isNull, lte, or, sql } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { paperNotificationBatches as batches, summaries } from "@/lib/db/schema";
import { getPaperNotifier } from "@/lib/papers/notifier";
import { notifyPaperChanged } from "./notifications";

/** An agent writing a paper saves many times in a row: the owner hears once it has paused. */
export const PAPER_NOTIFICATION_DELAY_MS = 5 * 60_000;
const LEASE_MS = 10 * 60_000;

/**
 * Queues (or pushes back) the paper's alert. After a save, it must immediately follow the revision
 * CAS in the same SQLite batch: changes() fences it. A new paper's alert stays "added".
 */
export function queuePaperChangesStatement(db: Database, paperId: string, revision: number, now: Date, created = false) {
  return db.run(sql`
    INSERT INTO paper_notification_batches (paper_id, created, revision, due_at)
    SELECT ${paperId}, ${created ? 1 : 0}, ${revision}, ${now.getTime() + PAPER_NOTIFICATION_DELAY_MS}
    WHERE ${created ? sql`1` : sql`changes() > 0`}
    ON CONFLICT (paper_id) DO UPDATE SET
      created = max(created, excluded.created), revision = excluded.revision,
      due_at = excluded.due_at, runner_id = NULL, lease_until = NULL
  `);
}

/** Batches are keyed by paper. Persistence already succeeded; a failed start is recovered by the notification cron. */
export async function startPaperNotification(paperId: string): Promise<void> {
  await getPaperNotifier().start(paperId);
}

type Plan =
  | { status: "done" }
  | { status: "wait"; nextAt: number }
  | { status: "deliver"; revision: number };

/** Competing runs use a lease; a save meanwhile pushes the delay back and clears it. */
export async function planPaperNotification(db: Database, paperId: string, runnerId: string, now = new Date()): Promise<Plan> {
  const [row] = await db.select().from(batches).where(eq(batches.paperId, paperId));
  if (!row) return { status: "done" };
  if (row.dueAt > now) return { status: "wait", nextAt: row.dueAt.getTime() };
  // A duplicate run can stop: the owner of the lease continues, or the cron recovers it.
  if (row.runnerId !== runnerId && row.leaseUntil && row.leaseUntil > now) return { status: "done" };
  const claimed = await db.update(batches).set({ runnerId, leaseUntil: new Date(now.getTime() + LEASE_MS) })
    .where(and(eq(batches.paperId, paperId), eq(batches.revision, row.revision),
      or(eq(batches.runnerId, runnerId), isNull(batches.leaseUntil), lte(batches.leaseUntil, now))));
  if (!claimed.rowsAffected) return { status: "wait", nextAt: now.getTime() + 1000 };
  return { status: "deliver", revision: row.revision };
}

/**
 * Takes the batch (only the revision planned: a save since starts its quiet period again) and
 * sends it. Taking it first makes a retried step send at most once.
 */
export async function deliverPaperNotification(db: Database, paperId: string, runnerId: string, revision: number): Promise<boolean> {
  const [taken] = await db.delete(batches)
    .where(and(eq(batches.paperId, paperId), eq(batches.revision, revision), eq(batches.runnerId, runnerId)))
    .returning();
  if (!taken) {
    const [row] = await db.select({ paperId: batches.paperId }).from(batches).where(eq(batches.paperId, paperId));
    return !row;
  }
  const [summary] = await db.select().from(summaries).where(eq(summaries.id, taken.paperId));
  if (summary) await notifyPaperChanged(db, summary, taken.created);
  return true;
}

/** Safety net for an interrupted workflow start or a run that exhausted its retries. */
export async function resumePaperNotifications(db: Database, now = new Date()): Promise<{ restartedPapers: number }> {
  const rows = await db.select({ paperId: batches.paperId }).from(batches)
    .where(and(lte(batches.dueAt, now), or(isNull(batches.leaseUntil), lte(batches.leaseUntil, now))))
    .orderBy(asc(batches.dueAt)).limit(100);
  let restartedPapers = 0;
  for (const row of rows) {
    try { await startPaperNotification(row.paperId); restartedPapers += 1; }
    catch { console.warn("[paper-notifications] workflow start failed"); }
  }
  return { restartedPapers };
}
