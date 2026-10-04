import { createHash, randomBytes } from "node:crypto";
import { and, desc, eq, isNull, lt, or, sql } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import type { Database } from "@/lib/db/client";
import { apiKeys, users, type ApiKeyRow } from "@/lib/db/schema";
import { ApiError, notFound } from "@/lib/http/errors";

/** Every key starts with this, so it is recognisable (and scannable) when leaked. */
export const API_KEY_PREFIX = "chippy_";
export const MAX_API_KEYS_PER_USER = 25;
/** `lastUsedAt` is refreshed at most this often, so a busy agent doesn't write on every request. */
const LAST_USED_RESOLUTION_MS = 60_000;

/** The `ApiKey` JSON object. The key itself is never returned after creation. */
export interface ApiKeyJson {
  id: string;
  name: string;
  /** The key's first and last characters, e.g. `chippy_Ab3x…9fQz`. */
  hint: string;
  toolCallCount: number;
  summariesAddedCount: number;
  lastUsedAt: string | null;
  createdAt: string;
}

/** Keys are 256-bit random values, so an unsalted SHA-256 is enough to make the stored hash useless. */
export function hashApiKey(key: string): string {
  return createHash("sha256").update(key, "utf8").digest("hex");
}

export function toApiKeyJson(row: ApiKeyRow): ApiKeyJson {
  return {
    id: row.id,
    name: row.name,
    hint: row.hint,
    toolCallCount: row.toolCallCount,
    summariesAddedCount: row.summariesAddedCount,
    lastUsedAt: row.lastUsedAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
  };
}

export async function listApiKeys(db: Database, ownerId: string): Promise<ApiKeyJson[]> {
  const rows = await db.select().from(apiKeys).where(eq(apiKeys.ownerId, ownerId)).orderBy(desc(apiKeys.createdAt), desc(apiKeys.id));
  return rows.map(toApiKeyJson);
}

/** Creates a key and returns it in full, the only time it can be read. */
export async function createApiKey(db: Database, ownerId: string, name: string, now = new Date()): Promise<{ key: string; apiKey: ApiKeyJson }> {
  const [{ count }] = await db.select({ count: sql<number>`count(*)` }).from(apiKeys).where(eq(apiKeys.ownerId, ownerId));
  if (count >= MAX_API_KEYS_PER_USER) {
    throw new ApiError(409, "API_KEY_LIMIT_REACHED", `You can have at most ${MAX_API_KEYS_PER_USER} API keys. Revoke one you no longer use first.`);
  }
  const key = `${API_KEY_PREFIX}${randomBytes(32).toString("base64url")}`;
  const [row] = await db.insert(apiKeys).values({
    id: crypto.randomUUID(),
    ownerId,
    name,
    keyHash: hashApiKey(key),
    hint: `${key.slice(0, API_KEY_PREFIX.length + 4)}…${key.slice(-4)}`,
    createdAt: now,
  }).returning();
  return { key, apiKey: toApiKeyJson(row) };
}

export async function renameApiKey(db: Database, ownerId: string, id: string, name: string): Promise<ApiKeyJson> {
  const [row] = await db.update(apiKeys).set({ name }).where(and(eq(apiKeys.id, id), eq(apiKeys.ownerId, ownerId))).returning();
  if (!row) throw notFound("The API key does not exist");
  return toApiKeyJson(row);
}

/** Revoking deletes the key: agents using it get `401` from the next request on. */
export async function revokeApiKey(db: Database, ownerId: string, id: string): Promise<void> {
  const deleted = await db.delete(apiKeys).where(and(eq(apiKeys.id, id), eq(apiKeys.ownerId, ownerId))).returning({ id: apiKeys.id });
  if (deleted.length === 0) throw notFound("The API key does not exist");
}

export interface ApiKeyPrincipal extends ApiPrincipal {
  apiKeyId: string;
}

/** Resolves `Authorization: Bearer chippy_…` to the key's owner, or null when it is unknown or revoked. */
export async function authenticateApiKey(db: Database, key: string, now = new Date()): Promise<ApiKeyPrincipal | null> {
  if (!key.startsWith(API_KEY_PREFIX) || key.length > 200) return null;
  const rows = await db.select({ key: apiKeys, email: users.email, name: users.name })
    .from(apiKeys)
    .innerJoin(users, eq(users.id, apiKeys.ownerId))
    .where(eq(apiKeys.keyHash, hashApiKey(key)))
    .limit(1);
  const match = rows[0];
  if (!match) return null;
  await db.update(apiKeys)
    .set({ lastUsedAt: now })
    .where(and(eq(apiKeys.id, match.key.id), or(isNull(apiKeys.lastUsedAt), lt(apiKeys.lastUsedAt, new Date(now.getTime() - LAST_USED_RESOLUTION_MS)))));
  return {
    sub: match.key.ownerId,
    clientId: "api-key",
    email: match.email ?? undefined,
    name: match.name ?? undefined,
    scopes: [],
    apiKeyId: match.key.id,
  };
}

/** Counts one tool call (and, for a saved chip, one added summary) against the key. */
export async function recordApiKeyUsage(db: Database, id: string, usage: { summaryAdded?: boolean } = {}, now = new Date()): Promise<void> {
  await db.update(apiKeys).set({
    toolCallCount: sql`${apiKeys.toolCallCount} + 1`,
    ...(usage.summaryAdded ? { summariesAddedCount: sql`${apiKeys.summariesAddedCount} + 1` } : {}),
    lastUsedAt: now,
  }).where(eq(apiKeys.id, id));
}
