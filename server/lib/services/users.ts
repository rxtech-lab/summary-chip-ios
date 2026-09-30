import { eq } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import type { Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";

const MAX_ENSURED_ENTRIES = 10_000;

/** Per-database cache of users already inserted, so each instance writes each user once. */
const ensured = new WeakMap<Database, Map<string, Promise<void>>>();

function entriesFor(db: Database): Map<string, Promise<void>> {
  let entries = ensured.get(db);
  if (!entries) {
    entries = new Map();
    ensured.set(db, entries);
  }
  return entries;
}

/** Makes sure a `users` row exists so owner foreign keys resolve. */
export async function ensureUser(db: Database, principal: ApiPrincipal): Promise<void> {
  const entries = entriesFor(db);
  const existing = entries.get(principal.sub);
  if (existing) return existing;
  if (entries.size >= MAX_ENSURED_ENTRIES) {
    const oldest = entries.keys().next();
    if (!oldest.done) entries.delete(oldest.value);
  }
  const insertion = db.insert(users)
    .values({ id: principal.sub, email: principal.email ?? null, name: principal.name ?? null, createdAt: new Date() })
    .onConflictDoNothing({ target: users.id })
    .then(() => undefined);
  entries.set(principal.sub, insertion);
  try {
    await insertion;
  } catch (error) {
    if (entries.get(principal.sub) === insertion) entries.delete(principal.sub);
    throw error;
  }
}

export async function getUser(db: Database, id: string) {
  const rows = await db.select().from(users).where(eq(users.id, id)).limit(1);
  return rows[0];
}
