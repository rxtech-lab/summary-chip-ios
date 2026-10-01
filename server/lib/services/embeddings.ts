import { and, asc, eq, isNull, ne, or, sql } from "drizzle-orm";
import type { AiProvider } from "@/lib/ai/provider";
import type { Database } from "@/lib/db/client";
import { summaries, summaryEmbeddings, type SummaryRow } from "@/lib/db/schema";

/** How much of the original text joins the card fields in a summary's embedding. */
const CONTENT_CHARS = 2_000;
const BACKFILL_BATCH_SIZE = 50;

/** A query embedding, only comparable with summary embeddings of the same model. */
export interface QueryVector {
  model: string;
  /** JSON array literal for libSQL's `vector32()`. */
  json: string;
}

type EmbeddableRow = Pick<SummaryRow, "title" | "summary" | "highlights" | "tags" | "keywords" | "category" | "siteName" | "sourceTitle" | "contentText">;

/** The text a summary is embedded from: its card fields plus the start of the original content. */
export function embeddingText(row: EmbeddableRow): string {
  return [
    row.title,
    row.sourceTitle && row.sourceTitle !== row.title ? row.sourceTitle : null,
    row.summary,
    row.highlights.join("\n"),
    `Category: ${row.category}`,
    row.tags.length ? `Tags: ${row.tags.join(", ")}` : null,
    row.keywords.length ? `Keywords: ${row.keywords.join(", ")}` : null,
    row.siteName ? `Site: ${row.siteName}` : null,
    row.contentText ? row.contentText.slice(0, CONTENT_CHARS) : null,
  ].filter(Boolean).join("\n");
}

function vectorLiteral(vector: number[]): string {
  return JSON.stringify(vector.map((value) => (Number.isFinite(value) ? value : 0)));
}

/** Embeds a search query, or null when semantic search is off or the model failed (callers fall back to keywords). */
export async function embedQuery(ai: AiProvider, query: string): Promise<QueryVector | null> {
  const model = ai.embeddingModelId();
  const text = query.trim();
  if (!model || !text) return null;
  try {
    const [vector] = await ai.embed([text]);
    return vector?.length ? { model, json: vectorLiteral(vector) } : null;
  } catch (error) {
    console.warn("[embeddings] query embedding failed; using keyword search", error);
    return null;
  }
}

async function storeEmbeddings(db: Database, model: string, entries: { id: string; vector: number[] }[], now = new Date()): Promise<void> {
  if (entries.length === 0) return;
  const statements = entries.map(({ id, vector }) => {
    const embedding = sql`vector32(${vectorLiteral(vector)})`;
    return db.insert(summaryEmbeddings).values({ summaryId: id, model, embedding, updatedAt: now })
      .onConflictDoUpdate({ target: summaryEmbeddings.summaryId, set: { model, embedding, updatedAt: now } });
  });
  await db.batch(statements as unknown as Parameters<typeof db.batch>[0]);
}

export interface SummaryEmbedding {
  model: string;
  vector: number[];
}

/** Computes a summary's embedding without storing it, or null when semantic search is off or the model failed. */
export async function embedSummary(ai: AiProvider, row: EmbeddableRow): Promise<SummaryEmbedding | null> {
  const model = ai.embeddingModelId();
  if (!model) return null;
  try {
    const [vector] = await ai.embed([embeddingText(row)]);
    return vector?.length ? { model, vector } : null;
  } catch (error) {
    console.warn("[embeddings] summary embedding failed", error);
    return null;
  }
}

/** Stores a computed embedding for an existing summary. Best effort: returns whether it was saved. */
export async function saveSummaryEmbedding(db: Database, summaryId: string, embedding: SummaryEmbedding | null): Promise<boolean> {
  if (!embedding) return false;
  try {
    await storeEmbeddings(db, embedding.model, [{ id: summaryId, vector: embedding.vector }]);
    return true;
  } catch (error) {
    console.warn(`[embeddings] storing ${summaryId} failed`, error);
    return false;
  }
}

/**
 * (Re)computes and stores one summary's embedding. A failure only leaves the summary findable by
 * keywords until the backfill picks it up.
 */
export async function indexSummary(db: Database, ai: AiProvider, row: EmbeddableRow & Pick<SummaryRow, "id">): Promise<boolean> {
  return saveSummaryEmbedding(db, row.id, await embedSummary(ai, row));
}

/**
 * Embeds summaries that have no embedding yet, or one from a different model (after
 * `AI_EMBEDDING_MODEL` changes). Bounded per run; the cleanup cron calls it daily.
 */
export async function backfillEmbeddings(db: Database, ai: AiProvider, options: { maxBatches?: number; batchSize?: number } = {}): Promise<{ embedded: number; failed: number }> {
  const model = ai.embeddingModelId();
  const report = { embedded: 0, failed: 0 };
  if (!model) return report;
  const batchSize = options.batchSize ?? BACKFILL_BATCH_SIZE;
  let afterId = "";
  for (let batch = 0; batch < (options.maxBatches ?? 10); batch += 1) {
    const rows = await db.select({
      id: summaries.id,
      title: summaries.title,
      summary: summaries.summary,
      highlights: summaries.highlights,
      tags: summaries.tags,
      keywords: summaries.keywords,
      category: summaries.category,
      siteName: summaries.siteName,
      sourceTitle: summaries.sourceTitle,
      contentText: summaries.contentText,
    })
      .from(summaries)
      .leftJoin(summaryEmbeddings, eq(summaryEmbeddings.summaryId, summaries.id))
      .where(and(sql`${summaries.id} > ${afterId}`, or(isNull(summaryEmbeddings.summaryId), ne(summaryEmbeddings.model, model))))
      .orderBy(asc(summaries.id))
      .limit(batchSize);
    if (rows.length === 0) break;
    afterId = rows[rows.length - 1].id;
    try {
      const vectors = await ai.embed(rows.map(embeddingText));
      await storeEmbeddings(db, model, rows.map((row, index) => ({ id: row.id, vector: vectors[index] })).filter((entry) => entry.vector?.length));
      report.embedded += rows.length;
    } catch (error) {
      console.warn("[embeddings] backfill batch failed", error);
      report.failed += rows.length;
    }
    if (rows.length < batchSize) break;
  }
  return report;
}
