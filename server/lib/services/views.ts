import { and, desc, eq, inArray, sql } from "drizzle-orm";
import type { Category } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { summaries, summaryTags, summaryViews, type SummaryRow } from "@/lib/db/schema";
import { notFound } from "@/lib/http/errors";
import { isPublicAndLive, searchCondition } from "./search";
import { publicOgImageUrl, shareUrlFor, toSummaryJson, type SummaryJson } from "./serialize";
import { findPublicSummaryBySlug, isLinkLive } from "./summaries";

/**
 * Records that a signed-in user opened someone else's public summary. Owner views are not recorded
 * (the owner already has it in their library) and do not bump the counter.
 */
export async function recordView(db: Database, userId: string, slug: string, now = new Date()): Promise<SummaryJson> {
  const row = await findPublicSummaryBySlug(db, slug);
  if (!row) throw notFound();
  if (row.ownerId === userId) return toSummaryJson(row, userId);
  await db.batch([
    db.insert(summaryViews).values({ userId, summaryId: row.id, viewedAt: now })
      .onConflictDoUpdate({ target: [summaryViews.userId, summaryViews.summaryId], set: { viewedAt: now } }),
    db.update(summaries).set({ viewCount: sql`${summaries.viewCount} + 1` }).where(eq(summaries.id, row.id)),
  ]);
  return toSummaryJson({ ...row, viewCount: row.viewCount + 1 }, userId);
}

/* ------------------------------------------------------------------------------------------------
 * Chat tool backends — scoped to the caller's own summaries plus their view history.
 * ---------------------------------------------------------------------------------------------- */

export interface ChatSearchInput {
  query?: string;
  category?: Category;
  tag?: string;
  scope: "all" | "mine" | "viewed";
  limit?: number;
}

export interface ChatSearchResult {
  id: string;
  slug: string;
  title: string;
  summary: string;
  category: string;
  tags: string[];
  siteName: string | null;
  sourceUrl: string | null;
  shareUrl: string;
  ogImageUrl: string;
  createdAt: string;
  viewedAt?: string;
}

function toResult(row: SummaryRow, viewedAt?: Date): ChatSearchResult {
  return {
    id: row.id,
    slug: row.slug,
    title: row.title,
    summary: row.summary,
    category: row.category,
    tags: row.tags,
    siteName: row.siteName,
    sourceUrl: row.sourceUrl,
    shareUrl: shareUrlFor(row.slug),
    ogImageUrl: publicOgImageUrl(row),
    createdAt: row.createdAt.toISOString(),
    ...(viewedAt ? { viewedAt: viewedAt.toISOString() } : {}),
  };
}

export async function searchForChat(db: Database, userId: string, input: ChatSearchInput): Promise<{ results: ChatSearchResult[] }> {
  const limit = Math.min(Math.max(input.limit ?? 8, 1), 20);
  const filters = [];
  const query = input.query?.trim();
  if (query) filters.push(searchCondition(query));
  if (input.category) filters.push(eq(summaries.category, input.category));
  if (input.tag) {
    filters.push(inArray(summaries.id, db.select({ id: summaryTags.summaryId }).from(summaryTags).where(eq(summaryTags.tag, input.tag.toLowerCase()))));
  }
  const [mine, viewed] = await Promise.all([
    input.scope === "viewed" ? Promise.resolve([]) : db.select().from(summaries)
      .where(and(eq(summaries.ownerId, userId), ...filters))
      .orderBy(desc(summaries.createdAt)).limit(limit),
    input.scope === "mine" ? Promise.resolve([]) : db.select({ summary: summaries, viewedAt: summaryViews.viewedAt })
      .from(summaryViews)
      .innerJoin(summaries, eq(summaries.id, summaryViews.summaryId))
      .where(and(eq(summaryViews.userId, userId), isPublicAndLive(), ...filters))
      .orderBy(desc(summaryViews.viewedAt)).limit(limit),
  ]);
  const merged = new Map<string, { row: SummaryRow; viewedAt?: Date; sortKey: number }>();
  for (const row of mine) merged.set(row.id, { row, sortKey: row.createdAt.getTime() });
  for (const entry of viewed) {
    if (!merged.has(entry.summary.id)) {
      merged.set(entry.summary.id, { row: entry.summary, viewedAt: entry.viewedAt, sortKey: entry.viewedAt.getTime() });
    }
  }
  const results = [...merged.values()]
    .sort((a, b) => b.sortKey - a.sortKey)
    .slice(0, limit)
    .map((entry) => toResult(entry.row, entry.viewedAt));
  return { results };
}

/** A summary the caller owns, or a public one they have viewed; includes the content excerpt. */
export async function getSummaryForChat(db: Database, userId: string, id: string): Promise<{ summary: SummaryJson & { contentExcerpt: string } }> {
  const rows = await db.select().from(summaries).where(eq(summaries.id, id)).limit(1);
  const row = rows[0];
  if (!row) throw notFound();
  if (row.ownerId !== userId) {
    if (!isLinkLive(row)) throw notFound();
    const view = await db.select({ userId: summaryViews.userId }).from(summaryViews)
      .where(and(eq(summaryViews.userId, userId), eq(summaryViews.summaryId, id))).limit(1);
    if (!view[0]) throw notFound();
  }
  return { summary: { ...toSummaryJson(row, userId), contentExcerpt: row.contentExcerpt } };
}
