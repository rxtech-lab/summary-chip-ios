import { and, asc, desc, eq, gt, sql } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { miniApps, miniAppMembers, miniAppRecords, miniAppRuns, summaries, summaryTags, users, type VersionActor } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { versionStatements } from "@/lib/services/document-versions";
import { shareUrlFor } from "@/lib/services/serialize";
import { validMiniApp } from "./validation";
import { fingerprint } from "./secrets";
import { evaluate } from "./expressions";
import { validateFields, type Json, type MiniAppDocument, type MiniQuery } from "@/lib/contracts/mini-app";
import { designMiniAppCover } from "./cover";
import { selectCoverTheme } from "@/lib/services/cover-colors";
import { coverImages, deleteObjects, resolveDeps, type ServiceDeps } from "@/lib/services/summaries";

export function miniEnabled() {
  if (process.env.MINI_APPS_ENABLED !== "true" && process.env.NODE_ENV !== "test") throw new ApiError(503, "MINI_APPS_DISABLED", "Mini Apps are not enabled on this server yet");
}
export async function miniAccess(db: Database, appId: string, userId: string, ownerOnly = false) {
  const [row] = await db.select({ app: miniApps, summary: summaries }).from(miniApps).innerJoin(summaries, eq(summaries.id, miniApps.summaryId)).where(eq(miniApps.summaryId, appId));
  if (!row) throw new ApiError(404, "NOT_FOUND", "Mini App not found");
  const [user] = await db.select().from(users).where(eq(users.id, userId));
  const email = user?.email?.toLowerCase() ?? "";
  const owner = row.summary.ownerId === userId;
  const [member] = owner ? [] : await db.select().from(miniAppMembers).where(and(eq(miniAppMembers.appId, appId), eq(miniAppMembers.email, email)));
  if ((!owner && !member) || (ownerOnly && !owner)) throw new ApiError(404, "NOT_FOUND", "Mini App not found");
  return { ...row, userId, email, owner, permissions: member?.permissions ?? {} };
}
export async function getMiniApp(db: Database, appId: string, userId: string) {
  const access = await miniAccess(db, appId, userId);
  return { id: appId, openUrl: `summarychip://summary/${appId}`, document: access.app.document, revision: access.app.revision, isOwner: access.owner, shareUrl: shareUrlFor(access.summary.slug), permissions: access.permissions };
}
export async function listMiniApps(db: Database, userId: string, cursor?: string) {
  const rows = await db.select({ id: miniApps.summaryId, title: summaries.title, revision: miniApps.revision }).from(miniApps).innerJoin(summaries, eq(summaries.id, miniApps.summaryId))
    .where(and(eq(summaries.ownerId, userId), cursor ? gt(miniApps.summaryId, cursor) : undefined)).orderBy(asc(miniApps.summaryId)).limit(11);
  return { count: Math.min(rows.length, 10), items: rows.slice(0, 10), nextCursor: rows.length > 10 ? rows[9].id : null };
}
const DEFAULT_THEME = { colors: ["#6366f1", "#22d3ee"], mode: "light" as const, emoji: "▦", accent: "#6366f1" };

/** A designed theme and AI-illustrated cover, like trips and papers get. A failed render leaves the theme without images. */
async function miniAppCover(db: Database, userId: string, id: string, document: MiniAppDocument, deps: ServiceDeps) {
  const { ai, store, now } = await resolveDeps(deps);
  const draft = await designMiniAppCover(ai, id, document);
  const theme = await selectCoverTheme(db, userId, draft.theme);
  const imageKeys = await coverImages(store, ai, id, { ...draft, theme }, null, "illustration", now(), "mini_app");
  return { store, language: draft.language, keywords: draft.keywords, theme, ogHeadline: draft.headline, imageStyle: "illustration" as const, ...imageKeys };
}

/** `cover`: have the AI design the theme and draw the cover art (agent-created apps), instead of the plain default theme. */
export async function createMiniApp(db: Database, userId: string, input: unknown, actor: VersionActor = "owner", options: ServiceDeps & { cover?: boolean } = {}) {
  const document = await validMiniApp(input);
  const id = crypto.randomUUID(); const now = new Date();
  const { store, ...cover } = options.cover ? await miniAppCover(db, userId, id, document, options) : { store: null, language: "en", theme: DEFAULT_THEME };
  try {
    await db.batch([
      db.insert(summaries).values({ id, slug: crypto.randomUUID().replaceAll("-", "").slice(0, 12), ownerId: userId, kind: "mini_app", sourceType: "text", source: "text", title: document.title, summary: document.description || "Interactive Mini App", contentText: document.description, contentExcerpt: document.description, highlights: [], category: "Technology", tags: ["mini-app"], keywords: [], visibility: "private", ttlDays: null, expiresAt: null, ...cover }),
      db.insert(miniApps).values({ summaryId: id, document }), db.insert(summaryTags).values({ summaryId: id, tag: "mini-app" }),
      ...versionStatements(db, { id, kind: "mini_app" }, document, { actor, at: now }),
    ]);
  } catch (error) {
    if (store && "ogImageKey" in cover) await deleteObjects(store, [cover.ogImageKey, cover.artImageKey]);
    throw error;
  }
  return getMiniApp(db, id, userId);
}
export async function updateMiniApp(db: Database, appId: string, userId: string, input: unknown, revision: number, actor: VersionActor = "owner", restoredFrom?: number) {
  const access = await miniAccess(db, appId, userId, true);
  if (access.app.revision !== revision) throw new ApiError(409, "MINI_REVISION_CONFLICT", "Reload the Mini App before saving", { revision: access.app.revision });
  const document = await validMiniApp(input);
  const incompatibleTables: string[] = [];
  for (const [tableId, before] of Object.entries(access.app.document.tables)) {
    const after = document.tables[tableId];
    const changed = !after || after.scope !== before.scope || Object.entries(before.fields).some(([key, f]) => !after.fields[key] || after.fields[key].type !== f.type || (!f.required && after.fields[key].required)) || Object.entries(after?.fields ?? {}).some(([key, f]) => !before.fields[key] && f.required);
    if (changed) {
      incompatibleTables.push(tableId);
      const [record] = await db.select({ id: miniAppRecords.id }).from(miniAppRecords).where(and(eq(miniAppRecords.appId, appId), eq(miniAppRecords.collection, tableId))).limit(1);
      if (record) throw new ApiError(409, "MINI_SCHEMA_MIGRATION_REQUIRED", "This change would invalidate stored records. Keep the existing table and add a new compatible table.", { table: tableId });
    }
  }
  const now = new Date();
  const results = await db.batch([
    db.update(miniApps).set({ document, revision: revision + 1, updatedAt: now }).where(and(eq(miniApps.summaryId, appId), eq(miniApps.revision, revision), ...incompatibleTables.map(table => sql`NOT EXISTS (SELECT 1 FROM mini_app_records WHERE app_id=${appId} AND collection=${table})`))).returning({ id: miniApps.summaryId }),
    ...versionStatements(db, { id: appId, kind: "mini_app" }, document, { actor, at: now, restoredFrom, fenced: true }),
    db.run(sql`UPDATE summaries SET title=${document.title}, summary=${document.description || "Interactive Mini App"}, content_text=${document.description}, content_excerpt=${document.description}, updated_at=${now.getTime()} WHERE id=${appId} AND EXISTS (SELECT 1 FROM mini_apps WHERE summary_id=${appId} AND revision=${revision + 1} AND document=${JSON.stringify(document)})`),
  ]);
  if (!results[0].length) throw new ApiError(409, "MINI_REVISION_CONFLICT", "The app changed while saving");
  return getMiniApp(db, appId, userId);
}
export async function tableAccess(db: Database, appId: string, userId: string, collection: string, write = false) {
  const access = await miniAccess(db, appId, userId);
  const table = access.app.document.tables[collection];
  if (!table) throw new ApiError(404, "MINI_TABLE_NOT_FOUND", "Table not found");
  if (table.scope === "shared" && !access.owner && (!access.permissions[collection] || (write && access.permissions[collection] !== "write"))) throw new ApiError(403, "MINI_TABLE_FORBIDDEN", "You do not have access to this shared table");
  return { ...access, table, partition: table.scope === "personal" ? userId : "shared" };
}
export async function queryMiniRecords(db: Database, appId: string, userId: string, query: MiniQuery, context: Record<string, Json> = {}, cursor?: string) {
  const access = await tableAccess(db, appId, userId, query.table);
  const offset = cursor ? Number(cursor) : 0;
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > 100_000) throw new ApiError(400, "INVALID_CURSOR", "Invalid cursor");
  const filters = query.filters.map(filter => {
    if (!access.table.fields[filter.field]) throw new ApiError(422, "MINI_QUERY_INVALID", "Unknown filter field");
    const field = sql`json_extract(${miniAppRecords.data}, ${`$.${filter.field}`})`;
    const value = evaluate(filter.value, context);
    if (value !== null && typeof value === "object") throw new ApiError(422, "MINI_QUERY_INVALID", "Filters require scalar values");
    switch (filter.op) {
      case "eq": return value === null ? sql`${field} IS NULL` : sql`${field} = ${value}`;
      case "ne": return value === null ? sql`${field} IS NOT NULL` : sql`${field} != ${value}`;
      case "gt": return sql`${field} > ${value}`;
      case "gte": return sql`${field} >= ${value}`;
      case "lt": return sql`${field} < ${value}`;
      case "lte": return sql`${field} <= ${value}`;
      case "contains": return sql`instr(CAST(${field} AS TEXT), ${String(value)}) > 0`;
    }
  });
  if (query.sort && !access.table.fields[query.sort.field]) throw new ApiError(422, "MINI_QUERY_INVALID", "Unknown sort field");
  const sort = query.sort ? sql`json_extract(${miniAppRecords.data}, ${`$.${query.sort.field}`})` : miniAppRecords.id;
  const rows = await db.select().from(miniAppRecords).where(and(eq(miniAppRecords.appId, appId), eq(miniAppRecords.collection, query.table), eq(miniAppRecords.partition, access.partition), ...filters))
    .orderBy(query.sort?.direction === "desc" ? desc(sort) : asc(sort), asc(miniAppRecords.id)).limit(query.limit + 1).offset(offset);
  return { items: rows.slice(0, query.limit).map(r => ({ id: r.id, data: r.data, revision: r.revision })), nextCursor: rows.length > query.limit ? String(offset + query.limit) : null };
}
export async function mutateMiniRecord(db: Database, appId: string, userId: string, table: string, operation: "create" | "update" | "delete", input: { id?: string; revision?: number; data?: unknown }) {
  const access = await tableAccess(db, appId, userId, table, true);
  const data = operation === "delete" ? {} : validateFields(input.data, access.table.fields);
  if (Buffer.byteLength(JSON.stringify(data)) > 100_000) throw new ApiError(422, "MINI_RECORD_TOO_LARGE", "Record exceeds 100 KB");
  const now = new Date();
  // Fence schema and membership checks at the write itself, including a concurrent definition edit.
  const fence = sql`EXISTS (SELECT 1 FROM mini_apps a JOIN summaries s ON s.id=a.summary_id WHERE a.summary_id=${appId} AND a.revision=${access.app.revision}
    AND (s.owner_id=${userId} OR EXISTS (SELECT 1 FROM mini_app_members m JOIN users u ON lower(u.email)=m.email WHERE m.app_id=a.summary_id AND u.id=${userId}
      AND (${access.table.scope === "personal" ? 1 : 0}=1 OR json_extract(m.permissions, ${`$.${table}`})='write'))))`;
  if (operation === "create") {
    const id = crypto.randomUUID();
    const created = await db.all(sql`INSERT INTO mini_app_records (id,app_id,collection,partition,user_id,data,revision,created_at,updated_at)
      SELECT ${id},${appId},${table},${access.partition},${access.table.scope === "personal" ? userId : null},${JSON.stringify(data)},0,${now.getTime()},${now.getTime()} WHERE ${fence} RETURNING id`);
    if (!created.length) throw new ApiError(409, "MINI_REVISION_CONFLICT", "The app or your permissions changed during this edit");
    return { id, revision: 0, data };
  }
  if (!input.id || !Number.isInteger(input.revision)) throw new ApiError(422, "MINI_RECORD_INVALID", "Record id and revision are required");
  const where = and(eq(miniAppRecords.id, input.id), eq(miniAppRecords.appId, appId), eq(miniAppRecords.collection, table), eq(miniAppRecords.partition, access.partition), eq(miniAppRecords.revision, input.revision!), fence);
  const rows = operation === "delete" ? await db.delete(miniAppRecords).where(where).returning() : await db.update(miniAppRecords).set({ data, revision: input.revision! + 1, updatedAt: now }).where(where).returning();
  if (!rows.length) throw new ApiError(409, "MINI_RECORD_CONFLICT", "The record changed or is unavailable. Refresh and retry.");
  return { id: input.id, revision: input.revision! + 1, data };
}

/** At-most-once management writes, including a lost response or a server restart. */
export async function mutateMiniRecordOnce(db: Database, appId: string, userId: string, input: { key: string; table: string; operation: "create" | "update" | "delete"; id?: string; revision?: number; data?: unknown }) {
  await tableAccess(db, appId, userId, input.table, true);
  const id = crypto.randomUUID(); const hash = fingerprint({ recordMutation: input });
  const [claimed] = await db.insert(miniAppRuns).values({ id, appId, userId, key: input.key, fingerprint: hash, status: "running" }).onConflictDoNothing().returning();
  if (!claimed) {
    const [prior] = await db.select().from(miniAppRuns).where(and(eq(miniAppRuns.appId, appId), eq(miniAppRuns.userId, userId), eq(miniAppRuns.key, input.key)));
    if (prior?.fingerprint !== hash) throw new ApiError(409, "MINI_IDEMPOTENCY_CONFLICT", "Request key was already used");
    if (prior.status === "complete") return prior.result;
    throw new ApiError(409, "MINI_ACTION_ALREADY_STARTED", "This edit already started. Refresh to check its result.");
  }
  try {
    const result = await mutateMiniRecord(db, appId, userId, input.table, input.operation, input);
    await db.update(miniAppRuns).set({ status: "complete", result }).where(eq(miniAppRuns.id, id)); return result;
  } catch (error) { await db.update(miniAppRuns).set({ status: "failed" }).where(eq(miniAppRuns.id, id)); throw error; }
}
