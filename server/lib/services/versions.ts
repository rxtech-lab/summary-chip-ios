import { and, desc, eq, lt, sql } from "drizzle-orm";
import type { PatchSummaryInput } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { documentVersions, type DocumentVersionRow, type SummaryKind, type VersionActor } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import type { ServiceDeps } from "./summaries";
import { getOwnedSummary, patchSummary } from "./summaries";
import type { SummaryJson } from "./serialize";
import type { BillingEnvironmentResolver } from "./translations";
import { VERSION_TITLE_PATHS, type VersionContent, type VersionContentByKind } from "./document-versions";
import { getOwnedTrip, saveDocument, validDocument, withStoredDefaults, type TripJson } from "./trips";
import { restorePaper, type PaperJson } from "./papers";

/** One row of `GET /api/v1/summaries/:id/versions`. */
export interface VersionJson {
  version: number;
  kind: SummaryKind;
  actor: VersionActor;
  /** The version a restore brought back; null otherwise. */
  restoredFrom: number | null;
  createdAt: string;
  /** The item's title in that version. */
  title: string;
  /** The version the item is at now. */
  isCurrent: boolean;
}

/** `GET /api/v1/summaries/:id/versions/:version`: the version with its content (see `VersionContentByKind`). */
export interface VersionDetailJson extends VersionJson {
  content: VersionContent;
}

/** `POST …/versions/:version/restore`: the item as restored, by kind, and the version the restore added (null when nothing changed). */
export interface RestoreJson {
  version: VersionJson | null;
  summary: SummaryJson | null;
  trip: TripJson | null;
  paper: PaperJson | null;
}

export const DEFAULT_VERSION_PAGE = 50;
export const MAX_VERSION_PAGE = 100;

function versionNotFound(version: number): ApiError {
  return new ApiError(404, "VERSION_NOT_FOUND", `Version ${version} does not exist (only the latest versions are kept)`);
}

function titleSql() {
  const cases = Object.entries(VERSION_TITLE_PATHS).map(([kind, path]) => sql`WHEN ${kind} THEN json_extract(${documentVersions.content}, ${path})`);
  return sql<string | null>`CASE ${documentVersions.kind} ${sql.join(cases, sql` `)} END`;
}

async function latestVersion(db: Database, summaryId: string): Promise<number | null> {
  const [row] = await db.select({ version: sql<number | null>`max(${documentVersions.version})` }).from(documentVersions).where(eq(documentVersions.summaryId, summaryId));
  return row?.version ?? null;
}

function toVersionJson(row: Pick<DocumentVersionRow, "version" | "kind" | "actor" | "restoredFrom" | "createdAt">, title: string | null, current: number | null): VersionJson {
  return {
    version: row.version,
    kind: row.kind,
    actor: row.actor,
    restoredFrom: row.restoredFrom,
    createdAt: row.createdAt.toISOString(),
    title: title ?? "",
    isCurrent: row.version === current,
  };
}

/**
 * The owner's versions of one of their items, newest first. `cursor` is the `nextCursor` of the
 * page before (the oldest version it listed). Versions hold text the owner may have removed, so
 * only the owner reads them.
 */
export async function listVersions(db: Database, ownerId: string, id: string, query: { cursor?: string; limit?: number } = {}): Promise<{ items: VersionJson[]; nextCursor: string | null }> {
  const summary = await getOwnedSummary(db, id, ownerId);
  const limit = Math.min(Math.max(query.limit ?? DEFAULT_VERSION_PAGE, 1), MAX_VERSION_PAGE);
  const before = query.cursor === undefined ? null : Number(query.cursor);
  if (before !== null && !(Number.isInteger(before) && before > 0)) throw new ApiError(400, "INVALID_CURSOR", "The pagination cursor is invalid");
  const [rows, current] = await Promise.all([
    db.select({
      version: documentVersions.version,
      kind: documentVersions.kind,
      actor: documentVersions.actor,
      restoredFrom: documentVersions.restoredFrom,
      createdAt: documentVersions.createdAt,
      title: titleSql(),
    })
      .from(documentVersions)
      .where(and(eq(documentVersions.summaryId, summary.id), before === null ? undefined : lt(documentVersions.version, before)))
      .orderBy(desc(documentVersions.version))
      .limit(limit + 1),
    latestVersion(db, summary.id),
  ]);
  const page = rows.slice(0, limit);
  return {
    items: page.map((row) => toVersionJson(row, row.title, current)),
    nextCursor: rows.length > limit ? String(page[page.length - 1]!.version) : null,
  };
}

async function findVersion(db: Database, summaryId: string, version: number): Promise<DocumentVersionRow> {
  const [row] = await db.select().from(documentVersions)
    .where(and(eq(documentVersions.summaryId, summaryId), eq(documentVersions.version, version))).limit(1);
  if (!row) throw versionNotFound(version);
  return row;
}

function titleOf(row: DocumentVersionRow): string {
  return row.kind === "trip"
    ? (row.content as unknown as VersionContentByKind["trip"]).document?.title ?? ""
    : (row.content as unknown as VersionContentByKind["summary" | "paper"]).title ?? "";
}

/** One of the owner's versions with its content. */
export async function getVersion(db: Database, ownerId: string, id: string, version: number): Promise<VersionDetailJson> {
  const summary = await getOwnedSummary(db, id, ownerId);
  const [row, current] = await Promise.all([findVersion(db, summary.id, version), latestVersion(db, summary.id)]);
  const content = row.kind === "trip"
    ? { document: withStoredDefaults((row.content as unknown as VersionContentByKind["trip"]).document) }
    : row.content as unknown as VersionContentByKind["summary" | "paper"];
  return { ...toVersionJson(row, titleOf(row), current), content };
}

/**
 * Brings a version back by saving its content as a new version (`actor: "restore"`), so the
 * restore can itself be undone. Only content comes back: sharing, reading language and cover stay.
 * A trip is restored over the latest revision; an app holding an older one gets a 409 on its next save.
 */
export async function restoreVersion(
  db: Database,
  ownerId: string,
  id: string,
  version: number,
  deps: Pick<ServiceDeps, "ai" | "now" | "store"> & { billingEnvironment?: BillingEnvironmentResolver } = {},
): Promise<RestoreJson> {
  const summary = await getOwnedSummary(db, id, ownerId);
  const row = await findVersion(db, summary.id, version);
  if (row.kind !== summary.kind) throw new ApiError(409, "VERSION_KIND_MISMATCH", "This version can't be restored onto the item");
  const before = await latestVersion(db, summary.id);
  const restore = { actor: "restore" as const, restoredFrom: version };
  let result: Omit<RestoreJson, "version">;
  if (row.kind === "trip") {
    const document = validDocument(withStoredDefaults((row.content as unknown as VersionContentByKind["trip"]).document), "Restoring this version");
    result = { summary: null, paper: null, trip: await saveTripVersion(db, ownerId, id, document, { ...deps, ...restore }) };
  } else if (row.kind === "paper") {
    // Manual edits not saved as a version yet are saved first, so the restore can be undone to them.
    result = { summary: null, trip: null, paper: await restorePaper(db, ownerId, id, row.content as unknown as VersionContentByKind["paper"], { ...deps, ...restore }) };
  } else {
    const content = row.content as unknown as VersionContentByKind["summary"];
    result = {
      trip: null,
      paper: null,
      summary: await patchSummary(db, ownerId, id, {
        title: content.title,
        summary: content.summary,
        highlights: content.highlights,
        // Saved as it was, even a category from before the current list.
        category: content.category as PatchSummaryInput["category"],
        tags: content.tags,
        keywords: content.keywords,
      }, { ...deps, ...restore, asWritten: true }),
    };
  }
  const after = await latestVersion(db, summary.id);
  if (after === null || after === before) return { version: null, ...result };
  const added = await findVersion(db, summary.id, after);
  return { version: toVersionJson(added, titleOf(added), after), ...result };
}

/** Saves `document` over the latest revision, retrying when another save lands in between. */
async function saveTripVersion(db: Database, ownerId: string, id: string, document: Parameters<typeof saveDocument>[4], deps: Parameters<typeof saveDocument>[1]): Promise<TripJson> {
  for (let attempt = 0; ; attempt += 1) {
    const { summary, trip } = await getOwnedTrip(db, id, ownerId);
    try {
      return await saveDocument(db, deps, summary, trip, document);
    } catch (error) {
      if (attempt < 2 && error instanceof ApiError && error.code === "TRIP_REVISION_CONFLICT") continue;
      throw error;
    }
  }
}

/** A `:version` path segment; anything but a positive integer is a 404. */
export function parseVersionNumber(value: string): number {
  const version = Number(value);
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(version) || version < 1) throw new ApiError(404, "VERSION_NOT_FOUND", "There is no such version");
  return version;
}
