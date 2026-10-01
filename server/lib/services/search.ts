import { and, eq, gt, isNull, or, sql, type SQL } from "drizzle-orm";
import type { SQLiteColumn } from "drizzle-orm/sqlite-core";
import { summaries, summaryEmbeddings } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import type { QueryVector } from "./embeddings";

const MAX_TOKENS = 8;

/**
 * Splits a query into search terms: whitespace-separated, trimmed of surrounding punctuation,
 * capped at 8. CJK runs stay whole (they are matched as substrings, which suits unsegmented text).
 *
 * Keyword search is plain `LIKE` rather than FTS5 because Turso Cloud databases run in MVCC mode,
 * which does not support virtual tables. Per-user result sets are small, so substring matching is
 * fine. Natural-language queries additionally match by meaning; see `relevance()`.
 */
export function searchTokens(input: string): string[] {
  return input
    .split(/\s+/u)
    .map((token) => token.replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, ""))
    .filter(Boolean)
    .slice(0, MAX_TOKENS);
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (char) => `\\${char}`);
}

const SEARCHABLE: (SQL | SQLiteColumn)[] = [
  summaries.title,
  summaries.summary,
  sql`${summaries.highlights}`,
  sql`${summaries.tags}`,
  sql`${summaries.keywords}`,
  summaries.category,
  sql`coalesce(${summaries.siteName}, '')`,
];

/**
 * WHERE fragment restricting `summaries` to rows matching `q`: every token must appear
 * (case-insensitively for ASCII) in at least one searchable field.
 */
export function searchCondition(q: string): SQL {
  const tokens = searchTokens(q);
  const terms = tokens.length ? tokens : [q.trim()];
  return and(...terms.map((term) => {
    const pattern = `%${escapeLike(term.toLowerCase())}%`;
    return or(...SEARCHABLE.map((column) => sql`lower(${column}) LIKE ${pattern} ESCAPE '\\'`))!;
  }))!;
}

/**
 * Cosine distance above which a summary is not considered a semantic match (0 = same meaning,
 * 1 = unrelated). Override with `SEARCH_MAX_DISTANCE`.
 */
export function maxSemanticDistance(): number {
  const configured = Number(process.env.SEARCH_MAX_DISTANCE);
  return Number.isFinite(configured) && configured > 0 && configured <= 2 ? configured : 0.65;
}

/** Subtracted from the distance of summaries that also contain every keyword, so exact hits lead. */
const KEYWORD_BOOST = 0.3;

/** Cosine distance between `summaries` rows and the query, or NULL for rows not embedded with the same model. */
export function vectorDistance(vector: QueryVector): SQL<number | null> {
  return sql<number | null>`(SELECT vector_distance_cos(${summaryEmbeddings.embedding}, vector32(${vector.json})) FROM ${summaryEmbeddings} WHERE ${summaryEmbeddings.summaryId} = ${summaries.id} AND ${summaryEmbeddings.model} = ${vector.model})`;
}

/**
 * Hybrid search over `summaries`: a row matches when it contains every keyword or is close in
 * meaning to the query. `score` ranks matches, lower is better. Without a query vector (semantic
 * search off or unavailable) it degrades to keyword matching with no score (every hit ranks the same).
 */
export function relevance(q: string, vector: QueryVector | null): { where: SQL; score: SQL<number> | null } {
  const keyword = searchCondition(q);
  if (!vector) return { where: keyword, score: null };
  const distance = vectorDistance(vector);
  return {
    where: or(keyword, sql`${distance} <= ${maxSemanticDistance()}`)!,
    score: sql<number>`(coalesce(${distance}, 1.0) - (CASE WHEN ${keyword} THEN ${KEYWORD_BOOST} ELSE 0 END))`,
  };
}

export function notExpired(now = new Date()): SQL {
  return or(isNull(summaries.expiresAt), gt(summaries.expiresAt, now))!;
}

export function isPublicAndLive(now = new Date()): SQL {
  return and(eq(summaries.visibility, "public"), notExpired(now))!;
}

/** Opaque keyset cursor: base64url of `[timestampMs, id]`. */
export function encodeCursor(time: Date, id: string): string {
  return Buffer.from(JSON.stringify([time.getTime(), id])).toString("base64url");
}

export function decodeCursor(cursor: string | undefined): { time: Date; id: string } | null {
  if (!cursor) return null;
  try {
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as unknown;
    if (Array.isArray(value) && typeof value[0] === "number" && typeof value[1] === "string") {
      return { time: new Date(value[0]), id: value[1] };
    }
  } catch {
    // fall through
  }
  throw new ApiError(400, "INVALID_CURSOR", "The pagination cursor is invalid");
}

/** Opaque offset cursor for relevance-ranked search results: base64url of `{"o": offset}`. */
export function encodeOffsetCursor(offset: number): string {
  return Buffer.from(JSON.stringify({ o: offset })).toString("base64url");
}

export function decodeOffsetCursor(cursor: string | undefined): number {
  if (!cursor) return 0;
  try {
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as unknown;
    const offset = (value as { o?: unknown } | null)?.o;
    if (typeof offset === "number" && Number.isInteger(offset) && offset >= 0 && offset <= 10_000) return offset;
  } catch {
    // fall through
  }
  throw new ApiError(400, "INVALID_CURSOR", "The pagination cursor is invalid");
}
