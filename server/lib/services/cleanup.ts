import { and, asc, eq, gt, inArray, isNotNull, isNull, lt, lte, or } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { summaries, uploads } from "@/lib/db/schema";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { rotateImageKeys } from "./summaries";
import { retireTranslatedCovers } from "./translations";
import { cleanupOAuth } from "@/lib/mcp/oauth-tokens";

const BATCH_SIZE = 100;
const MAX_BATCHES = 50;
const ORPHAN_UPLOAD_AGE_MS = 24 * 60 * 60 * 1000;
/** Links that expired this recently get their OG image retired; wide enough to survive missed cron runs. */
const EXPIRED_LINK_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

export interface CleanupReport {
  expiredLinks: number;
  orphanUploads: number;
  objectsDeleted: number;
  objectFailures: number;
}

/** Millisecond timestamp embedded in an `og/<id>-<ts>-<hex>.png` key. */
function ogKeyTimestamp(key: string): number | null {
  const match = /-(\d+)-[0-9a-f]+\.png$/.exec(key);
  return match ? Number(match[1]) : null;
}

/**
 * Summaries are never deleted by expiry — `expiresAt` only ends the public link. For links that just
 * expired, the images move to fresh keys so their CDN URLs stop working (same as going private).
 * Also deletes never-attached uploads older than a day.
 */
export async function runCleanup(db: Database, options: { store?: ObjectStore; now?: Date } = {}): Promise<CleanupReport> {
  const store = options.store ?? getObjectStore();
  const now = options.now ?? new Date();
  await cleanupOAuth(db, now);
  const report: CleanupReport = { expiredLinks: 0, orphanUploads: 0, objectsDeleted: 0, objectFailures: 0 };

  let after: { expiresAt: Date; id: string } | null = null;
  for (let batch = 0; batch < MAX_BATCHES; batch += 1) {
    const conditions = [
      eq(summaries.visibility, "public"),
      isNotNull(summaries.ogImageKey),
      gt(summaries.expiresAt, new Date(now.getTime() - EXPIRED_LINK_WINDOW_MS)),
      lte(summaries.expiresAt, now),
    ];
    if (after) {
      conditions.push(or(gt(summaries.expiresAt, after.expiresAt), and(eq(summaries.expiresAt, after.expiresAt), gt(summaries.id, after.id)))!);
    }
    const rows = await db.select({ id: summaries.id, ogImageKey: summaries.ogImageKey, artImageKey: summaries.artImageKey, expiresAt: summaries.expiresAt })
      .from(summaries)
      .where(and(...conditions))
      .orderBy(asc(summaries.expiresAt), asc(summaries.id))
      .limit(BATCH_SIZE);
    if (rows.length === 0) break;
    const last = rows[rows.length - 1];
    after = { expiresAt: last.expiresAt!, id: last.id };
    for (const row of rows) {
      const keyTime = row.ogImageKey ? ogKeyTimestamp(row.ogImageKey) : null;
      // Already rotated at or after expiry (or an unrecognised key): nothing to retire.
      if (!row.ogImageKey || keyTime === null || keyTime >= row.expiresAt!.getTime()) continue;
      const { changes, retired } = await rotateImageKeys(store, row, now);
      // The OG key's timestamp marks the row as handled, so it must move for the rotation to count.
      if (!changes.ogImageKey) {
        report.objectFailures += 1;
        continue;
      }
      await db.update(summaries).set(changes).where(eq(summaries.id, row.id));
      await retireTranslatedCovers(db, store, [row.id]);
      report.expiredLinks += 1;
      for (const key of retired) {
        try {
          await store.delete(key);
          report.objectsDeleted += 1;
        } catch {
          report.objectFailures += 1;
        }
      }
    }
    if (rows.length < BATCH_SIZE) break;
  }

  const cutoff = new Date(now.getTime() - ORPHAN_UPLOAD_AGE_MS);
  for (let batch = 0; batch < MAX_BATCHES; batch += 1) {
    const rows = await db.select({ key: uploads.key }).from(uploads)
      .where(and(isNull(uploads.attachedAt), lt(uploads.createdAt, cutoff)))
      .limit(BATCH_SIZE);
    if (rows.length === 0) break;
    const results = await Promise.allSettled(rows.map((row) => store.delete(row.key)));
    const deletedKeys = rows.filter((_, index) => results[index].status === "fulfilled").map((row) => row.key);
    report.objectFailures += rows.length - deletedKeys.length;
    report.objectsDeleted += deletedKeys.length;
    if (deletedKeys.length === 0) break;
    await db.delete(uploads).where(inArray(uploads.key, deletedKeys));
    report.orphanUploads += deletedKeys.length;
    if (rows.length < BATCH_SIZE) break;
  }
  return report;
}
