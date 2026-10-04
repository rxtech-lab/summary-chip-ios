import { and, asc, desc, eq, or, sql, type SQL } from "drizzle-orm";
import type { AiProvider } from "@/lib/ai/provider";
import {
  CONTENT_PREFIX_CHARS,
  DUPLICATE_CONTENT_CHARS,
  MIN_CONTENT_PREFIX_CHARS,
  normalizeSourceUrl,
  sameContentStart,
  type ChipListing, type ChipRecord, type DuplicateInput } from "@/lib/ai/duplicate-agent";
import type { Database } from "@/lib/db/client";
import { summaries, type SummaryRow } from "@/lib/db/schema";
import { embedQuery } from "./embeddings";
import { escapeLike, relevance } from "./search";

const MAX_CANDIDATES = 10;
const SEARCH_LIMIT = 8;

const listing = {
  id: summaries.id,
  title: summaries.title,
  summary: summaries.summary,
  sourceUrl: summaries.sourceUrl,
  sourceTitle: summaries.sourceTitle,
  siteName: summaries.siteName,
};

/** The owner's chips closest to `query` by meaning or keywords, most relevant first. */
async function searchOwn(db: Database, ai: AiProvider, ownerId: string, query: string, limit = SEARCH_LIMIT): Promise<ChipListing[]> {
  const match = relevance(query, await embedQuery(ai, query));
  return db.select(listing).from(summaries)
    .where(and(eq(summaries.ownerId, ownerId), match.where))
    .orderBy(...(match.score ? [asc(match.score)] : []), desc(summaries.createdAt))
    .limit(limit);
}

/**
 * The owner's chips worth checking against the incoming one: those with the same source URL
 * (normalised), title or source title, or start of content, then the closest in meaning.
 */
async function duplicateCandidates(db: Database, ai: AiProvider, ownerId: string, input: DuplicateInput): Promise<ChipListing[]> {
  const url = normalizeSourceUrl(input.sourceUrl);
  const own = eq(summaries.ownerId, ownerId);
  // `sameContentStart` in SQL: the texts agree over the shorter one's opening.
  const start = input.text.trim().slice(0, CONTENT_PREFIX_CHARS);
  const span = sql`min(length(trim(${summaries.contentText})), ${start.length})`;
  const exact: SQL[] = [
    sql`lower(${summaries.title}) = ${input.title.trim().toLowerCase()}`,
    sql`(${span} >= ${MIN_CONTENT_PREFIX_CHARS} AND substr(trim(${summaries.contentText}), 1, ${span}) = substr(${start}, 1, ${span}))`,
  ];
  if (input.sourceTitle) exact.push(sql`lower(${summaries.sourceTitle}) = ${input.sourceTitle.trim().toLowerCase()}`);

  const [matches, sameHost, similar] = await Promise.all([
    db.select(listing).from(summaries).where(and(own, or(...exact))).orderBy(desc(summaries.createdAt)).limit(MAX_CANDIDATES),
    // Narrowed by host in SQL, then compared normalised (tracking parameters, "www.", trailing slash).
    url
      ? db.select(listing).from(summaries)
        .where(and(own, sql`lower(${summaries.sourceUrl}) LIKE ${`%${escapeLike(url.split(/[/?]/, 1)[0])}%`} ESCAPE '\\'`))
        .orderBy(desc(summaries.createdAt)).limit(200)
      : Promise.resolve([]),
    searchOwn(db, ai, ownerId, `${input.title}\n${input.summary}`, 5),
  ]);
  const sameUrl = sameHost.filter((chip) => normalizeSourceUrl(chip.sourceUrl) === url);
  const merged = new Map<string, ChipListing>();
  for (const chip of [...sameUrl, ...matches, ...similar]) if (!merged.has(chip.id)) merged.set(chip.id, chip);
  return [...merged.values()].slice(0, MAX_CANDIDATES);
}

async function readOwn(db: Database, ownerId: string, id: string): Promise<ChipRecord | null> {
  const rows = await db.select({ ...listing, content: sql<string>`substr(${summaries.contentText}, 1, ${DUPLICATE_CONTENT_CHARS})` })
    .from(summaries)
    .where(and(eq(summaries.id, id), eq(summaries.ownerId, ownerId)))
    .limit(1);
  return rows[0] ?? null;
}

export interface Duplicate {
  row: SummaryRow;
  reason: string;
}

/**
 * Asks the duplicate agent whether an incoming chip is already in the owner's library, comparing
 * source, title and content. The agent only runs when the library has candidates. When it fails,
 * a chip with the same source URL or content start still counts as a duplicate.
 */
export async function findDuplicateChip(db: Database, ai: AiProvider, ownerId: string, input: DuplicateInput): Promise<Duplicate | null> {
  const candidates = await duplicateCandidates(db, ai, ownerId, input);
  if (candidates.length === 0) return null;
  const verdict = await ai.findDuplicate(input, {
    candidates,
    search: (query) => searchOwn(db, ai, ownerId, query),
    read: (id) => readOwn(db, ownerId, id),
  });

  let match: { id: string; reason: string } | null = verdict?.duplicateOf ? { id: verdict.duplicateOf, reason: verdict.reason } : null;
  if (!verdict) {
    const url = normalizeSourceUrl(input.sourceUrl);
    for (const chip of candidates) {
      const record = await readOwn(db, ownerId, chip.id);
      if (url && normalizeSourceUrl(chip.sourceUrl) === url) match = { id: chip.id, reason: "Same source URL." };
      else if (record && sameContentStart(record.content, input.text)) match = { id: chip.id, reason: "Same content." };
      if (match) break;
    }
  }
  if (!match) return null;
  const rows = await db.select().from(summaries).where(and(eq(summaries.id, match.id), eq(summaries.ownerId, ownerId))).limit(1);
  return rows[0] ? { row: rows[0], reason: match.reason } : null;
}
