import { eq, sql } from "drizzle-orm";
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

/** Makes sure a `users` row exists so owner foreign keys resolve, with the email from the latest token. */
export async function ensureUser(db: Database, principal: ApiPrincipal): Promise<void> {
  const entries = entriesFor(db);
  // Keyed with the email too, so a token with a new email writes it.
  const key = `${principal.sub}\n${principal.email ?? ""}`;
  const existing = entries.get(key);
  if (existing) return existing;
  if (entries.size >= MAX_ENSURED_ENTRIES) {
    const oldest = entries.keys().next();
    if (!oldest.done) entries.delete(oldest.value);
  }
  const insertion = db.insert(users)
    .values({ id: principal.sub, email: principal.email ?? null, name: principal.name ?? null, createdAt: new Date() })
    // Keeps the email current: invited share links are matched against it.
    .onConflictDoUpdate({ target: users.id, set: { email: sql`coalesce(excluded.email, ${users.email})` } })
    .then(() => undefined);
  entries.set(key, insertion);
  try {
    await insertion;
  } catch (error) {
    if (entries.get(key) === insertion) entries.delete(key);
    throw error;
  }
}

export async function getUser(db: Database, id: string) {
  const rows = await db.select().from(users).where(eq(users.id, id)).limit(1);
  return rows[0];
}
