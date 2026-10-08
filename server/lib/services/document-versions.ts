import { sql } from "drizzle-orm";
import type { TripDocument } from "@/lib/contracts/trip";
import type { Database } from "@/lib/db/client";
import type { SummaryKind, SummaryRow, VersionActor } from "@/lib/db/schema";

/**
 * What a version keeps of each kind of library item: its content, never its sharing, reading
 * language or cover. A new kind adds its content here (and its restore in `versions.ts`).
 */
export interface VersionContentByKind {
  summary: Pick<SummaryRow, "title" | "summary" | "highlights" | "category" | "tags" | "keywords">;
  trip: { document: TripDocument };
}

export type VersionContent = VersionContentByKind[SummaryKind];

/** How many versions each item keeps; older ones are dropped as new ones are saved. */
export const MAX_DOCUMENT_VERSIONS = 100;

/** Where each kind's title sits in its content, for listing versions without loading them. */
export const VERSION_TITLE_PATHS: Record<SummaryKind, string> = {
  summary: "$.title",
  trip: "$.document.title",
};

export function summaryContent(row: VersionContentByKind["summary"]): VersionContentByKind["summary"] {
  return { title: row.title, summary: row.summary, highlights: row.highlights, category: row.category, tags: row.tags, keywords: row.keywords };
}

export function tripContent(document: TripDocument): VersionContentByKind["trip"] {
  return { document };
}

export interface VersionOptions {
  /** Who is saving; the owner in the app unless said otherwise. */
  actor?: VersionActor;
  /** Set by a restore: the version it brings back. */
  restoredFrom?: number;
}

/**
 * Statements for a batch that save `content` as the item's next version and drop the ones beyond
 * `MAX_DOCUMENT_VERSIONS`. With `fenced`, the version is only saved when the statement before it
 * changed a row, so a save refused by a compare-and-swap leaves no version.
 */
export function versionStatements(
  db: Database,
  item: { id: string; kind: SummaryKind },
  content: VersionContent,
  options: VersionOptions & { at: Date; fenced?: boolean },
) {
  return [
    db.run(sql`
      INSERT INTO document_versions (summary_id, version, kind, content, actor, restored_from, created_at)
      SELECT ${item.id}, coalesce((SELECT max(version) FROM document_versions WHERE summary_id = ${item.id}), 0) + 1,
        ${item.kind}, ${JSON.stringify(content)}, ${options.actor ?? "owner"}, ${options.restoredFrom ?? null}, ${options.at.getTime()}
      ${options.fenced ? sql`WHERE changes() > 0` : sql``}
    `),
    db.run(sql`
      DELETE FROM document_versions WHERE summary_id = ${item.id}
        AND version <= (SELECT max(version) FROM document_versions WHERE summary_id = ${item.id}) - ${MAX_DOCUMENT_VERSIONS}
    `),
  ] as const;
}
