import { and, eq, gt, isNull, or, sql, type SQL } from "drizzle-orm";
import type { SQLiteColumn } from "drizzle-orm/sqlite-core";
import { summaries } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";

const MAX_TOKENS = 8;

/**
 * Splits a query into search terms: whitespace-separated, trimmed of surrounding punctuation,
 * capped at 8. CJK runs stay whole (they are matched as substrings, which suits unsegmented text).
 *
 * Search is plain `LIKE` rather than FTS5 because Turso Cloud databases run in MVCC mode, which
 * does not support virtual tables. Per-user result sets are small, so substring matching is fine.
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
