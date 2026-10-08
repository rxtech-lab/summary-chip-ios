import { and, asc, desc, eq, inArray, sql, type SQL } from "drizzle-orm";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import type { Category, TranslationLanguage } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { summaries, summaryTags, summaryViews, type SummaryRow } from "@/lib/db/schema";
import { siteNameFor } from "@/lib/extract/platforms";
import { ApiError, notFound } from "@/lib/http/errors";
import { embedQuery } from "./embeddings";
import { relevance } from "./search";
import { canViewerRead, findGrantToken, readableByViewer, resolveShareKey } from "./share-access";
import { publicOgImageUrl, shareUrlFor, toSummaryJson, type SummaryJson } from "./serialize";
import { readSummaryJson } from "./summaries";
import type { BillingEnvironmentResolver } from "./translations";
import { getOwnedTrip, listTrips, toTripJson } from "./trips";

/**
 * Records that a signed-in user opened someone else's summary from a link: its own `slug` link, or
 * a share link's token. A share link is remembered with the view, so the summary stays in their
 * library while that link lets them in. Owner views are not recorded and do not bump the counter.
 */
export async function recordView(
  db: Database,
  userId: string,
  slug: string,
  options: { email?: string | null; authorization?: string | null; accepted?: TranslationLanguage | null; ai?: AiProvider; now?: Date; billingEnvironment?: BillingEnvironmentResolver } = {},
): Promise<SummaryJson> {
  const now = options.now ?? new Date();
  const resolved = await resolveShareKey(db, slug, { id: userId, email: options.email, authorization: options.authorization }, now);
  if (resolved.status === "not-invited") {
    throw new ApiError(403, "NOT_INVITED", "This link is only for the people it was shared with");
  }
  if (resolved.status !== "ok") throw notFound();
  const { row, link } = resolved;
  // Opened from a shared link: in the reader's language (the owner's in their chosen one).
  const read = (summary: typeof row) => readSummaryJson(db, summary, userId, options.accepted ?? null, {
    ai: options.ai,
    billingEnvironment: options.billingEnvironment,
    ...(link ? { grantToken: link.token } : {}),
  });
  if (row.ownerId === userId) return read(row);
  // A later visit through the summary's own link keeps the share link they were given.
  const shareLinkId = link?.id ?? null;
  await db.batch([
    db.insert(summaryViews).values({ userId, summaryId: row.id, viewedAt: now, shareLinkId })
      .onConflictDoUpdate({
        target: [summaryViews.userId, summaryViews.summaryId],
        set: { viewedAt: now, shareLinkId: sql`coalesce(excluded.share_link_id, ${summaryViews.shareLinkId})` },
      }),
    db.update(summaries).set({ viewCount: sql`${summaries.viewCount} + 1` }).where(eq(summaries.id, row.id)),
  ]);
  return read({ ...row, viewCount: row.viewCount + 1 });
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
  kind: SummaryRow["kind"];
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
    kind: row.kind,
    slug: row.slug,
    title: row.title,
    summary: row.summary,
    category: row.category,
    tags: row.tags,
    siteName: siteNameFor(row.siteName, row.sourceUrl),
    sourceUrl: row.sourceUrl,
    shareUrl: shareUrlFor(row.slug),
    ogImageUrl: publicOgImageUrl(row),
    createdAt: row.createdAt.toISOString(),
    ...(viewedAt ? { viewedAt: viewedAt.toISOString() } : {}),
  };
}

/**
 * The agent's search tool. `query` is natural language: summaries match by meaning (vector
 * distance) or keywords and come back most relevant first; without a query, newest first.
 */
export async function searchForChat(
  db: Database,
  userId: string,
  input: ChatSearchInput,
  ai?: AiProvider,
): Promise<{ query?: string; semantic: boolean; results: ChatSearchResult[] }> {
  const limit = Math.min(Math.max(input.limit ?? 8, 1), 20);
  const filters: SQL[] = [];
  const query = input.query?.trim();
  const vector = query ? await embedQuery(ai ?? await getAiProvider(), query) : null;
  const match = query ? relevance(query, vector) : null;
  if (match) filters.push(match.where);
  if (input.category) filters.push(eq(summaries.category, input.category));
  if (input.tag) {
    filters.push(inArray(summaries.id, db.select({ id: summaryTags.summaryId }).from(summaryTags).where(eq(summaryTags.tag, input.tag.toLowerCase()))));
  }
  // Without a vector every match ranks the same; a bare `0` would read as a column ordinal in ORDER BY.
  const score = match?.score ?? null;
  const rank = score ? [asc(score)] : [];
  const scoreColumn = (score ?? sql<number>`(0)`).mapWith(Number);
  const [mine, viewed] = await Promise.all([
    input.scope === "viewed" ? Promise.resolve([]) : db.select({ summary: summaries, score: scoreColumn }).from(summaries)
      .where(and(eq(summaries.ownerId, userId), ...filters))
      .orderBy(...rank, desc(summaries.createdAt)).limit(limit),
    input.scope === "mine" ? Promise.resolve([]) : db.select({ summary: summaries, viewedAt: summaryViews.viewedAt, score: scoreColumn })
      .from(summaryViews)
      .innerJoin(summaries, eq(summaries.id, summaryViews.summaryId))
      .where(and(eq(summaryViews.userId, userId), readableByViewer(userId), ...filters))
      .orderBy(...rank, desc(summaryViews.viewedAt)).limit(limit),
  ]);
  const merged = new Map<string, { row: SummaryRow; viewedAt?: Date; score: number; time: number }>();
  for (const { summary, score } of mine) merged.set(summary.id, { row: summary, score, time: summary.createdAt.getTime() });
  for (const entry of viewed) {
    if (!merged.has(entry.summary.id)) {
      merged.set(entry.summary.id, { row: entry.summary, viewedAt: entry.viewedAt, score: entry.score, time: entry.viewedAt.getTime() });
    }
  }
  const results = [...merged.values()]
    .sort((a, b) => a.score - b.score || b.time - a.time)
    .slice(0, limit)
    .map((entry) => toResult(entry.row, entry.viewedAt));
  return { ...(query ? { query } : {}), semantic: vector !== null, results };
}

/** Lists actual owned trips, without depending on search terms or embedding coverage. */
export async function listTripsForChat(db: Database, userId: string) {
  const { trips } = await listTrips(db, userId);
  if (!trips.length) return { results: [] };
  const rows = await db.select().from(summaries)
    .where(and(eq(summaries.ownerId, userId), eq(summaries.kind, "trip")));
  const byId = new Map(rows.map((row) => [row.id, row]));
  return {
    results: trips.flatMap((trip) => {
      const row = byId.get(trip.id);
      return row ? [{ ...toResult(row), ...trip }] : [];
    }),
  };
}

/** Reads the full diary of an owned trip and supplies its tappable library card. */
export async function getTripForChat(db: Database, userId: string, id: string) {
  const { summary, trip } = await getOwnedTrip(db, id, userId);
  return { summary: toResult(summary), trip: toTripJson(summary, trip, userId) };
}

/** A summary the caller owns, or a public one they have viewed; includes the content excerpt. */
export async function getSummaryForChat(db: Database, userId: string, id: string): Promise<{ summary: SummaryJson & { contentExcerpt: string } }> {
  const rows = await db.select().from(summaries).where(eq(summaries.id, id)).limit(1);
  const row = rows[0];
  if (!row) throw notFound();
  let grantToken: string | null = null;
  if (row.ownerId !== userId) {
    if (!await canViewerRead(db, row, userId)) throw notFound();
    const view = await db.select({ userId: summaryViews.userId }).from(summaryViews)
      .where(and(eq(summaryViews.userId, userId), eq(summaryViews.summaryId, id))).limit(1);
    if (!view[0]) throw notFound();
    grantToken = await findGrantToken(db, id, userId);
  }
  return { summary: { ...toSummaryJson(row, userId, null, undefined, null, grantToken), contentExcerpt: row.contentExcerpt } };
}
