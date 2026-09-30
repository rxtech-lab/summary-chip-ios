import { and, asc, eq, isNotNull, isNull, lte, notLike } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { summaries, uploads, users } from "@/lib/db/schema";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { purgeSummaries } from "./summaries";

/**
 * Delayed account deletion, mirrored from the identity provider.
 *
 * rxlab-auth owns whether the account exists and runs its own 7-day timer, but notifies no relying
 * party when it finalizes. So this server keeps its own copy of the deadline (adopted from the IdP's
 * answer) and purges the user's summaries, PDFs and OG images on its own cron.
 */

export const DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS = 7 * 24 * 60 * 60;
const BATCH_SIZE = 100;

/** Read at call time so tests can shorten the grace period. */
export function getAccountDeletionDelaySeconds(): number {
  const raw = process.env.ACCOUNT_DELETION_DELAY_SECONDS?.trim();
  if (!raw || !/^\d+$/.test(raw)) return DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS;
  return Math.min(Number.parseInt(raw, 10), 365 * 24 * 60 * 60);
}

/** Whole seconds, so the instant we advertise is the instant a later read returns. */
function floorToSecond(value: Date): Date {
  return new Date(Math.floor(value.getTime() / 1000) * 1000);
}

export interface PendingDeletion {
  scheduledAt: Date;
  requestedAt: Date;
  requestId: string;
}

const DELETION_COLUMNS = {
  deletionScheduledAt: users.deletionScheduledAt,
  deletionRequestedAt: users.deletionRequestedAt,
  deletionRequestId: users.deletionRequestId,
} as const;

function toPending(row: { deletionScheduledAt: Date | null; deletionRequestedAt: Date | null; deletionRequestId: string | null }): PendingDeletion | null {
  if (!row.deletionScheduledAt || !row.deletionRequestedAt || !row.deletionRequestId) return null;
  return { scheduledAt: row.deletionScheduledAt, requestedAt: row.deletionRequestedAt, requestId: row.deletionRequestId };
}

export async function getPendingDeletion(db: Database, userId: string): Promise<PendingDeletion | null> {
  const [row] = await db.select(DELETION_COLUMNS).from(users).where(eq(users.id, userId)).limit(1);
  return row ? toPending(row) : null;
}

/** Idempotent: an account already pending keeps its original deadline. */
export async function scheduleAccountDeletion(
  db: Database,
  userId: string,
  options: { scheduledAt?: Date; now?: Date } = {},
): Promise<PendingDeletion> {
  const now = floorToSecond(options.now ?? new Date());
  const scheduledAt = floorToSecond(options.scheduledAt ?? new Date(now.getTime() + getAccountDeletionDelaySeconds() * 1000));
  const [row] = await db.update(users)
    .set({ deletionScheduledAt: scheduledAt, deletionRequestedAt: now, deletionRequestId: crypto.randomUUID() })
    .where(and(eq(users.id, userId), isNull(users.deletionScheduledAt)))
    .returning(DELETION_COLUMNS);
  const pending = row ? toPending(row) : await getPendingDeletion(db, userId);
  if (!pending) throw new Error(`Could not schedule deletion for ${userId}`);
  return pending;
}

/** Clears a pending deletion; false when none was pending or a sweep already claimed it. */
export async function cancelAccountDeletion(db: Database, userId: string): Promise<boolean> {
  const cleared = await db.update(users)
    .set({ deletionScheduledAt: null, deletionRequestedAt: null, deletionRequestId: null })
    .where(and(
      eq(users.id, userId),
      isNotNull(users.deletionScheduledAt),
      // Too late once a sweep has started purging.
      notLike(users.deletionRequestId, "finalizing:%"),
    ))
    .returning({ id: users.id });
  return cleared.length > 0;
}

export interface AccountPurgeReport {
  deletedAccounts: number;
  deletedSummaries: number;
  objectFailures: number;
}

/**
 * Deletes one account whose schedule came due. The claim re-checks the fencing token and deadline
 * in the WHERE clause, so a deletion cancelled (or cancelled and re-requested) since the sweep
 * read it is left alone.
 */
export async function finalizeAccountDeletion(
  db: Database,
  userId: string,
  requestId: string,
  options: { store?: ObjectStore; now?: Date } = {},
): Promise<AccountPurgeReport | null> {
  const store = options.store ?? getObjectStore();
  const now = options.now ?? new Date();
  const claimed = await db.update(users)
    .set({ deletionRequestId: `finalizing:${requestId}` })
    .where(and(
      eq(users.id, userId),
      eq(users.deletionRequestId, requestId),
      isNotNull(users.deletionScheduledAt),
      lte(users.deletionScheduledAt, now),
    ))
    .returning({ id: users.id });
  if (claimed.length === 0) return null;

  const report: AccountPurgeReport = { deletedAccounts: 0, deletedSummaries: 0, objectFailures: 0 };
  for (;;) {
    const rows = await db.select({ id: summaries.id, ogImageKey: summaries.ogImageKey, artImageKey: summaries.artImageKey, sourceFileKey: summaries.sourceFileKey })
      .from(summaries)
      .where(eq(summaries.ownerId, userId))
      .limit(BATCH_SIZE);
    if (rows.length === 0) break;
    const result = await purgeSummaries(db, store, rows);
    report.deletedSummaries += result.deleted;
    report.objectFailures += result.objectFailures;
  }

  // Uploads never attached to a summary have no row `purgeSummaries` would reach.
  const orphans = await db.select({ key: uploads.key }).from(uploads).where(eq(uploads.ownerId, userId));
  const results = await Promise.allSettled(orphans.map((row) => store.delete(row.key)));
  report.objectFailures += results.filter((result) => result.status === "rejected").length;

  // Cascades take the remaining uploads rows and every view record.
  await db.delete(users).where(eq(users.id, userId));
  report.deletedAccounts = 1;
  return report;
}

/**
 * Finalizes every deletion that has come due. `graceSeconds` is slack against clock skew with the
 * identity provider, so we never purge data in the minutes before the account itself goes.
 */
export async function sweepOverdueAccountDeletions(
  db: Database,
  options: { store?: ObjectStore; now?: Date; graceSeconds?: number; limit?: number } = {},
): Promise<AccountPurgeReport> {
  const now = options.now ?? new Date();
  const cutoff = new Date(now.getTime() - (options.graceSeconds ?? 300) * 1000);
  const overdue = await db.select({ id: users.id, requestId: users.deletionRequestId })
    .from(users)
    .where(and(isNotNull(users.deletionScheduledAt), lte(users.deletionScheduledAt, cutoff)))
    .orderBy(asc(users.deletionScheduledAt))
    .limit(options.limit ?? 50);

  const report: AccountPurgeReport = { deletedAccounts: 0, deletedSummaries: 0, objectFailures: 0 };
  for (const row of overdue) {
    if (!row.requestId) continue;
    // A `finalizing:` token means an earlier sweep died mid-purge; resume it under the same claim.
    const requestId = row.requestId.replace(/^finalizing:/, "");
    if (requestId !== row.requestId) {
      await db.update(users).set({ deletionRequestId: requestId }).where(and(eq(users.id, row.id), eq(users.deletionRequestId, row.requestId)));
    }
    const result = await finalizeAccountDeletion(db, row.id, requestId, { store: options.store, now });
    if (!result) continue;
    report.deletedAccounts += result.deletedAccounts;
    report.deletedSummaries += result.deletedSummaries;
    report.objectFailures += result.objectFailures;
  }
  return report;
}
