import { createHash } from "node:crypto";
import { and, eq } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { resumeReceipts } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import type { ResolvedResume } from "@/lib/services/resumes";

export type ResumeTransaction = Parameters<Parameters<Database["transaction"]>[0]>[0];

export function stableResumeJson(value: unknown): string {
  return JSON.stringify(value, (_, v) =>
    v && typeof v === "object" && !Array.isArray(v)
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((key) => [key, v[key]]),
        )
      : v,
  );
}

// Serialize writers in this worker and retry only SQLite's transient writer lock across workers.
const writes = new WeakMap<Database, Promise<unknown>>();
export async function mutateResume(
  db: Database,
  owner: string,
  key: string,
  request: unknown,
  run: (tx: ResumeTransaction) => Promise<ResolvedResume>,
) {
  const digest = createHash("sha256").update(stableResumeJson(request)).digest("hex");
  const task = (writes.get(db) ?? Promise.resolve())
    .catch(() => {})
    .then(async () => {
      for (let i = 0; ; i++) {
        try {
          return await db.transaction(async (tx) => {
            const [receipt] = await tx
              .select()
              .from(resumeReceipts)
              .where(and(eq(resumeReceipts.ownerId, owner), eq(resumeReceipts.key, key)));
            if (receipt) {
              if (receipt.requestHash !== digest)
                throw new ApiError(409, "IDEMPOTENCY_KEY_REUSED", "This key was already used for another operation");
              return receipt.result as ResolvedResume;
            }
            const result = await run(tx);
            await tx
              .insert(resumeReceipts)
              .values({ ownerId: owner, key, familyId: result.familyId, requestHash: digest, result });
            return result;
          });
        } catch (err) {
          const e = err as { code?: string; cause?: { code?: string } };
          if (i >= 4 || ![e.code, e.cause?.code].includes("SQLITE_BUSY")) throw err;
          await new Promise((done) => setTimeout(done, 25 * (i + 1)));
        }
      }
    });
  writes.set(db, task);
  try {
    return await task;
  } finally {
    if (writes.get(db) === task) writes.delete(db);
  }
}
