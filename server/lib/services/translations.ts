import { and, eq, inArray, isNotNull, isNull, lt, or } from "drizzle-orm";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { TRANSLATION_LANGUAGES, type TranslationLanguage } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { summaryTranslations, type SummaryRow, type SummaryTranslationRow } from "@/lib/db/schema";
import { runAfter } from "@/lib/http/after";
import type { ObjectStore } from "@/lib/storage/r2";
import { ApiError } from "@/lib/http/errors";
import { isSourceTranslationPending, ORIGINAL_READING, SOURCE_TRANSLATION_PENDING_MS, sourceMarkdownFor, type SummaryReading } from "./serialize";

/* ------------------------------------------------------------------------------------------------
 * Languages
 * ---------------------------------------------------------------------------------------------- */

/** The translation language a BCP 47 tag reads as (`zh-TW` → `zh-Hant`, `en-GB` → `en`), or null. */
export function translationLanguageFor(tag: string | null | undefined): TranslationLanguage | null {
  if (!tag) return null;
  const parts = tag.trim().replaceAll("_", "-").toLowerCase().split("-");
  if (parts[0] === "zh") {
    return parts.includes("hant") || parts.some((part) => part === "tw" || part === "hk" || part === "mo") ? "zh-Hant" : "zh-Hans";
  }
  return TRANSLATION_LANGUAGES.find((language) => language === parts[0]) ?? null;
}

/** The reader's most preferred language in an `Accept-Language` header that summaries can be read in, or null. */
export function preferredLanguage(header: string | null | undefined): TranslationLanguage | null {
  if (!header) return null;
  const ranked = header.split(",").map((entry, index) => {
    const [tag, ...params] = entry.trim().split(";");
    const q = params.map((param) => /^\s*q=([\d.]+)\s*$/i.exec(param)?.[1]).find(Boolean);
    return { tag: tag.trim(), q: q === undefined ? 1 : Number(q), index };
  }).filter((entry) => entry.tag && entry.tag !== "*" && entry.q > 0)
    .sort((a, b) => b.q - a.q || a.index - b.index);
  for (const entry of ranked) {
    const language = translationLanguageFor(entry.tag);
    if (language) return language;
  }
  return null;
}

export function acceptedLanguage(request: Request): TranslationLanguage | null {
  return preferredLanguage(request.headers.get("accept-language"));
}

/**
 * The language a viewer reads a summary in, or null for as written: the owner reads the language
 * they chose (`displayLanguage`), everyone else their own (`Accept-Language`).
 */
export function readingLanguage(
  row: Pick<SummaryRow, "ownerId" | "language" | "displayLanguage">,
  viewerId: string | null,
  accepted: TranslationLanguage | null,
): TranslationLanguage | null {
  const wanted = viewerId !== null && row.ownerId === viewerId ? translationLanguageFor(row.displayLanguage) : accepted;
  if (!wanted || translationLanguageFor(row.language) === wanted) return null;
  return wanted;
}

/* ------------------------------------------------------------------------------------------------
 * Translating
 * ---------------------------------------------------------------------------------------------- */

export async function findTranslation(db: Database, summaryId: string, language: TranslationLanguage): Promise<SummaryTranslationRow | undefined> {
  const rows = await db.select().from(summaryTranslations)
    .where(and(eq(summaryTranslations.summaryId, summaryId), eq(summaryTranslations.language, language))).limit(1);
  return rows[0];
}

function clip(value: string, max: number): string {
  const trimmed = value.trim();
  return trimmed.length <= max ? trimmed : `${trimmed.slice(0, max - 1).trimEnd()}…`;
}

/**
 * Translates the summary's title, summary and highlights and saves them, or returns null when the
 * model failed. The source document is translated separately (`startSourceTranslation`).
 */
async function translateCard(db: Database, ai: AiProvider, row: SummaryRow, language: TranslationLanguage, now = new Date()): Promise<SummaryTranslationRow | null> {
  const output = await ai.translateSummary({ title: row.title, summary: row.summary, highlights: row.highlights, headline: row.ogHeadline, from: row.language, to: language });
  if (!output?.title.trim() || !output.summary.trim()) return null;
  const translated = output.highlights.map((highlight) => clip(highlight, 300)).filter(Boolean);
  const translation: SummaryTranslationRow = {
    summaryId: row.id,
    language,
    title: clip(output.title, 200),
    summary: clip(output.summary, 1200),
    // A model that dropped highlights would silently lose key points; keep the originals then.
    highlights: translated.length === row.highlights.length ? translated : row.highlights,
    contentMarkdown: null,
    headline: row.ogHeadline && output.headline.trim() ? clip(output.headline, 120) : null,
    ogImageKey: null,
    createdAt: now,
    updatedAt: now,
  };
  await db.insert(summaryTranslations).values(translation).onConflictDoUpdate({
    target: [summaryTranslations.summaryId, summaryTranslations.language],
    set: { title: translation.title, summary: translation.summary, highlights: translation.highlights, headline: translation.headline, updatedAt: now },
  });
  return (await findTranslation(db, row.id, language)) ?? translation;
}

/**
 * Translates the kept source document after the response, once per language: the translation row
 * is claimed by marking it pending (""), so concurrent readers don't start a second run. A run that
 * was lost (pending past `SOURCE_TRANSLATION_PENDING_MS`) or failed (null) may be claimed again.
 * Returns the translation as the caller should serialise it (pending when a run was started).
 */
async function startSourceTranslation(db: Database, ai: AiProvider, row: SummaryRow, translation: SummaryTranslationRow, now = new Date()): Promise<SummaryTranslationRow> {
  const source = row.contentMarkdown;
  // Nothing kept, or the original is still being written: there is nothing to translate yet.
  if (!source || translation.contentMarkdown) return translation;
  const stale = new Date(now.getTime() - SOURCE_TRANSLATION_PENDING_MS);
  const claimed = await db.update(summaryTranslations)
    .set({ contentMarkdown: "", updatedAt: now })
    .where(and(
      eq(summaryTranslations.summaryId, row.id),
      eq(summaryTranslations.language, translation.language),
      or(isNull(summaryTranslations.contentMarkdown), and(eq(summaryTranslations.contentMarkdown, ""), lt(summaryTranslations.updatedAt, stale))),
    ))
    .returning({ summaryId: summaryTranslations.summaryId });
  if (claimed.length === 0) return translation;
  const language = translation.language as TranslationLanguage;
  runAfter(async () => {
    let markdown: string | null = null;
    try {
      markdown = await ai.translateDocument(source, language);
    } finally {
      // Never leave the row pending: a failed run becomes null and is retried on a later read.
      await db.update(summaryTranslations).set({ contentMarkdown: markdown || null, updatedAt: new Date() })
        .where(and(eq(summaryTranslations.summaryId, row.id), eq(summaryTranslations.language, language)));
    }
  });
  return { ...translation, contentMarkdown: "", updatedAt: now };
}

export interface ReadOptions {
  ai?: AiProvider;
  /** Fail with `502 TRANSLATION_FAILED` instead of falling back to the original text. */
  required?: boolean;
}

/**
 * One summary in `language` (null = as written): its saved translation, else one written now.
 * Starts translating the source document in the background when it has one. A failed translation
 * shows the original unless `required`.
 */
export async function readSummary(db: Database, row: SummaryRow, language: TranslationLanguage | null, options: ReadOptions = {}): Promise<SummaryReading> {
  if (!language) return ORIGINAL_READING;
  const ai = options.ai ?? await getAiProvider();
  let translation: SummaryTranslationRow | null = await findTranslation(db, row.id, language) ?? null;
  translation ??= await translateCard(db, ai, row, language);
  if (!translation) {
    if (options.required) throw new ApiError(502, "TRANSLATION_FAILED", "The summary could not be translated. Please try again.");
    return ORIGINAL_READING;
  }
  return { translation: await startSourceTranslation(db, ai, row, translation), pending: false };
}

/** Summaries translated at once in the background for a list page. */
const LIST_TRANSLATION_CONCURRENCY = 4;

/**
 * A page of summaries for one viewer: each in the language they read it in, from saved
 * translations. Missing ones are translated after the response and marked `pending`, so the list
 * returns at once; the client fetches it again to pick them up.
 */
export async function readSummaries(
  db: Database,
  rows: SummaryRow[],
  viewerId: string,
  accepted: TranslationLanguage | null,
  options: Pick<ReadOptions, "ai"> = {},
): Promise<Map<string, SummaryReading>> {
  const readings = new Map<string, SummaryReading>();
  const wanted = new Map(rows.map((row) => [row.id, readingLanguage(row, viewerId, accepted)]));
  const ids = rows.filter((row) => wanted.get(row.id)).map((row) => row.id);
  if (ids.length === 0) return readings;
  const saved = await db.select().from(summaryTranslations).where(inArray(summaryTranslations.summaryId, ids));
  const missing: { row: SummaryRow; language: TranslationLanguage }[] = [];
  for (const row of rows) {
    const language = wanted.get(row.id);
    if (!language) continue;
    const translation = saved.find((candidate) => candidate.summaryId === row.id && candidate.language === language);
    if (translation) {
      readings.set(row.id, { translation, pending: false });
    } else {
      readings.set(row.id, { translation: null, pending: true });
      missing.push({ row, language });
    }
  }
  if (missing.length) {
    runAfter(async () => {
      const ai = options.ai ?? await getAiProvider();
      let next = 0;
      const worker = async () => {
        while (next < missing.length) {
          const { row, language } = missing[next++];
          await translateCard(db, ai, row, language).catch((error) => console.warn("[translations] list translation failed", error));
        }
      };
      await Promise.all(Array.from({ length: Math.min(LIST_TRANSLATION_CONCURRENCY, missing.length) }, worker));
    });
  }
  return readings;
}

/** The source document in `language` when its translation is ready; otherwise the original, flagged pending while one is written. */
export async function readSourceMarkdown(
  db: Database,
  row: SummaryRow,
  viewerId: string | null,
  language: TranslationLanguage | null,
  options: Pick<ReadOptions, "ai"> = {},
): Promise<{ markdown: string; language: string; translationPending: boolean } | null> {
  const original = sourceMarkdownFor(row, viewerId);
  if (original === null) return null;
  const { translation } = await readSummary(db, row, language, options);
  if (translation?.contentMarkdown) return { markdown: translation.contentMarkdown, language: translation.language, translationPending: false };
  return { markdown: original, language: row.language, translationPending: translation?.contentMarkdown === "" };
}

/** The owner edited the title while reading a translation: the edit belongs to that translation. */
export async function renameTranslation(db: Database, summaryId: string, language: TranslationLanguage, title: string, now = new Date()): Promise<boolean> {
  const updated = await db.update(summaryTranslations).set({ title, updatedAt: now })
    .where(and(eq(summaryTranslations.summaryId, summaryId), eq(summaryTranslations.language, language)))
    .returning({ summaryId: summaryTranslations.summaryId });
  return updated.length > 0;
}

/** A saved translation of one summary, for the language picker. */
export interface TranslationStatus {
  language: string;
  /** The source document is translated too (false while it is written, or when there is none). */
  sourceTranslated: boolean;
  /** The translated source document is being written. */
  sourcePending: boolean;
}

/** The languages a summary has been translated into, in `TRANSLATION_LANGUAGES` order. */
export async function listTranslations(db: Database, summaryId: string, now = new Date()): Promise<TranslationStatus[]> {
  const rows = await db.select({
    language: summaryTranslations.language,
    contentMarkdown: summaryTranslations.contentMarkdown,
    updatedAt: summaryTranslations.updatedAt,
  }).from(summaryTranslations).where(eq(summaryTranslations.summaryId, summaryId));
  const order = (language: string) => TRANSLATION_LANGUAGES.indexOf(language as TranslationLanguage);
  return rows.sort((a, b) => order(a.language) - order(b.language)).map((row) => ({
    language: row.language,
    sourceTranslated: Boolean(row.contentMarkdown),
    sourcePending: isSourceTranslationPending(row, now),
  }));
}

/**
 * Forgets the covers drawn for a summary's translations and deletes them (best effort): their
 * public URLs must not outlive the original's when its keys rotate, it is redrawn or deleted.
 */
export async function retireTranslatedCovers(db: Database, store: ObjectStore, summaryIds: string[]): Promise<void> {
  if (summaryIds.length === 0) return;
  const rows = await db.select({ key: summaryTranslations.ogImageKey }).from(summaryTranslations)
    .where(and(inArray(summaryTranslations.summaryId, summaryIds), isNotNull(summaryTranslations.ogImageKey)));
  if (rows.length === 0) return;
  await db.update(summaryTranslations).set({ ogImageKey: null }).where(inArray(summaryTranslations.summaryId, summaryIds));
  await Promise.all(rows.map(({ key }) => store.delete(key!).catch((error) => console.warn("[translations] cover delete failed", error))));
}
