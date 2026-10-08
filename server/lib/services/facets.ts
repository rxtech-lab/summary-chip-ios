import { and, desc, eq, inArray, or, sql, type SQL } from "drizzle-orm";
import { CATEGORIES, type FacetQuery } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { summaries, summaryTags, summaryViews } from "@/lib/db/schema";
import { decodeOffsetCursor, encodeOffsetCursor, escapeLike } from "./search";
import { readableByViewer } from "./share-access";

/** Same universe as the library: own summaries plus viewed ones the caller may still open. */
function facetUniverse(db: Database, ownerId: string): SQL {
  const viewedIds = db.select({ id: summaryViews.summaryId }).from(summaryViews).where(eq(summaryViews.userId, ownerId));
  return or(eq(summaries.ownerId, ownerId), and(inArray(summaries.id, viewedIds), readableByViewer(ownerId)))!;
}

export async function getFacets(db: Database, ownerId: string) {
  const live = facetUniverse(db, ownerId);
  const count = sql<number>`count(*)`.mapWith(Number);
  const [categories, tags] = await Promise.all([
    db.select({ name: summaries.category, count }).from(summaries).where(live)
      .groupBy(summaries.category).orderBy(desc(count), summaries.category),
    db.select({ name: summaryTags.tag, count }).from(summaryTags)
      .innerJoin(summaries, eq(summaries.id, summaryTags.summaryId))
      .where(live).groupBy(summaryTags.tag).orderBy(desc(count), summaryTags.tag).limit(200),
  ]);
  return { categories, tags };
}

/**
 * One facet list for the filter combobox: names containing `q` (case-insensitive), most used first,
 * paged with an offset cursor. Categories are the closed list, so unused ones come back with count 0.
 */
export async function searchFacets(db: Database, ownerId: string, kind: "category" | "tag", query: FacetQuery) {
  const live = facetUniverse(db, ownerId);
  const offset = decodeOffsetCursor(query.cursor);
  const needle = query.q?.toLowerCase();
  const count = sql<number>`count(*)`.mapWith(Number);
  let items: { name: string; count: number }[];
  let more: boolean;
  if (kind === "category") {
    const rows = await db.select({ name: summaries.category, count }).from(summaries).where(live).groupBy(summaries.category);
    const counts = new Map(rows.map((row) => [row.name, row.count]));
    const all = [...new Set<string>([...CATEGORIES, ...counts.keys()])]
      .filter((name) => !needle || name.toLowerCase().includes(needle))
      .map((name) => ({ name, count: counts.get(name) ?? 0 }))
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
    items = all.slice(offset, offset + query.limit);
    more = all.length > offset + query.limit;
  } else {
    const conditions = [live];
    if (needle) conditions.push(sql`lower(${summaryTags.tag}) LIKE ${`%${escapeLike(needle)}%`} ESCAPE '\\'`);
    const rows = await db.select({ name: summaryTags.tag, count }).from(summaryTags)
      .innerJoin(summaries, eq(summaries.id, summaryTags.summaryId))
      .where(and(...conditions)).groupBy(summaryTags.tag).orderBy(desc(count), summaryTags.tag)
      .limit(query.limit + 1).offset(offset);
    items = rows.slice(0, query.limit);
    more = rows.length > query.limit;
  }
  return { items, nextCursor: more ? encodeOffsetCursor(offset + query.limit) : null };
}
