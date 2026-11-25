import { requireFlowcyAccess } from "@/lib/subscription/flowcy";
import type { SubscriptionEnvironment } from "@/lib/subscription/environment";
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

/** The language the summary's kept source document is in: its own when it was judged to differ. */
export function sourceLanguageOf(row: Pick<SummaryRow, "language" | "sourceLanguage">): string {
  return row.sourceLanguage ?? row.language;
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

/** Public readers can use saved translations or request new ones through the publisher’s access. */
export interface TranslationAccount {
  userId: string;
  environment?: SubscriptionEnvironment;
}

export function translationAccount(row: Pick<SummaryRow, "ownerId">, viewerId: string | null): TranslationAccount {
  return { userId: viewerId ?? row.ownerId };
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

function hasTranslatedTags(row: SummaryRow, translation: SummaryTranslationRow): boolean {
  return row.tags.length === 0 || (translation.tags !== null && translation.tags.length === row.tags.length);
}

/**
 * Translates the summary's title, summary, highlights and tag labels and saves them, or returns null when the
 * model failed. The source document is translated separately (`startSourceTranslation`).
 */
async function translateCard(
  db: Database,
  ai: AiProvider,
  row: SummaryRow,
  language: TranslationLanguage,
  now = new Date(),
  saved?: SummaryTranslationRow,
): Promise<SummaryTranslationRow | null> {
  const output = await ai.translateSummary({ title: row.title, summary: row.summary, highlights: row.highlights, tags: row.tags, headline: row.ogHeadline, from: row.language, to: language });
  if (!output?.title.trim() || !output.summary.trim()) return null;
  const tags = output.tags.map((tag) => clip(tag.replace(/^#/, ""), 80));
  // Chip labels must retain a one-to-one mapping to the original tags, including duplicates.
  if (tags.length !== row.tags.length || tags.some((tag) => !tag)) return null;
  if (saved) {
    // Upgrade older translations without overwriting renamed titles, covers or source documents.
    await db.update(summaryTranslations).set({ tags, updatedAt: now })
      .where(and(eq(summaryTranslations.summaryId, row.id), eq(summaryTranslations.language, language)));
    return { ...saved, tags, updatedAt: now };
  }
  const translated = output.highlights.map((highlight) => clip(highlight, 300)).filter(Boolean);
  const translation: SummaryTranslationRow = {
    summaryId: row.id,
    language,
    title: clip(output.title, 200),
    summary: clip(output.summary, 1200),
    // A model that dropped highlights would silently lose key points; keep the originals then.
    highlights: translated.length === row.highlights.length ? translated : row.highlights,
    tags,
    contentMarkdown: null,
    headline: row.ogHeadline && output.headline.trim() ? clip(output.headline, 120) : null,
    ogImageKey: null,
    createdAt: now,
    updatedAt: now,
  };
  await db.insert(summaryTranslations).values(translation).onConflictDoUpdate({
    target: [summaryTranslations.summaryId, summaryTranslations.language],
    set: { title: translation.title, summary: translation.summary, highlights: translation.highlights, tags, headline: translation.headline, updatedAt: now },
  });
  return (await findTranslation(db, row.id, language)) ?? translation;
}

/**
 * Translates the kept source document after the response, once per language: the translation row
 * is claimed by marking it pending (""), so concurrent readers don't start a second run. A run that
 * was lost (pending past `SOURCE_TRANSLATION_PENDING_MS`) or failed (null) may be claimed again.
 * If the account cannot start the translation, the original remains visible.
 */
async function startSourceTranslation(
  db: Database,
  ai: AiProvider,
  row: SummaryRow,
  translation: SummaryTranslationRow,
  account: TranslationAccount,
  now = new Date(),
): Promise<SummaryTranslationRow> {
  const source = row.contentMarkdown;
  // Nothing kept, or the original is still being written: there is nothing to translate yet.
  if (!source || translation.contentMarkdown) return translation;
  // The source is already in this language, though the chip isn't.
  if (translationLanguageFor(sourceLanguageOf(row)) === translation.language) return translation;
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
  const thisRow = and(eq(summaryTranslations.summaryId, row.id), eq(summaryTranslations.language, language));
  try {

    await requireFlowcyAccess(account.userId, account.environment);
  } catch (error) {
    // Let go of the claim so a later read can translate it.
    await db.update(summaryTranslations).set({ contentMarkdown: null }).where(and(thisRow, eq(summaryTranslations.contentMarkdown, "")));
    if (!(error instanceof ApiError)) throw error;
    console.info("[translations] source document not translated", error.code);
    return { ...translation, contentMarkdown: null };
  }
  runAfter(async () => {
    let markdown: string | null = null;
    try {
      markdown = await ai.translateDocument(source, language);
    } finally {
      // Never leave the row pending: a failed run becomes null and is retried on a later read.
      await db.update(summaryTranslations).set({ contentMarkdown: markdown || null, updatedAt: new Date() }).where(thisRow);
    }
  });
  return { ...translation, contentMarkdown: "", updatedAt: now };
}

export interface ReadOptions {
  ai?: AiProvider;
  /**
   * Fail with a translation or subscription error instead of falling back to
   * the original text.
   */
  required?: boolean;
}

/**
 * Reuses a saved translation or writes one for a subscribed account. Starts translating the
 * source document in the background. Falls back to the original unless `required`.
 */
export async function readSummary(
  db: Database,
  row: SummaryRow,
  language: TranslationLanguage | null,
  account: TranslationAccount,
  options: ReadOptions = {},
): Promise<SummaryReading> {
  if (!language || row.kind === "resume") return ORIGINAL_READING;
  const ai = options.ai ?? await getAiProvider();
  let translation: SummaryTranslationRow | null = await findTranslation(db, row.id, language) ?? null;
  if (!translation || !hasTranslatedTags(row, translation)) {
    const saved = translation;
    try {

    await requireFlowcyAccess(account.userId, account.environment);
    } catch (error) {
      if (options.required || !(error instanceof ApiError)) throw error;
      console.info("[translations] summary not translated; showing the original", error.code);
      return saved ? { translation: saved, pending: false } : ORIGINAL_READING;
    }
    const card = await translateCard(db, ai, row, language, new Date(), saved ?? undefined);
    translation = card ?? (options.required ? null : saved);
  }
  if (!translation) {
    if (options.required) throw new ApiError(502, "TRANSLATION_FAILED", "The summary could not be translated. Please try again.");
    return ORIGINAL_READING;
  }
  return { translation: await startSourceTranslation(db, ai, row, translation, account), pending: false };
}

/** Summaries translated at once in the background for a list page. */
const LIST_TRANSLATION_CONCURRENCY = 4;

/**
 * A page of summaries for one viewer: each in the language they read it in, from saved
 * translations. Missing ones are marked `pending` and translated after the response.
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
  const missing: { row: SummaryRow; language: TranslationLanguage; saved?: SummaryTranslationRow }[] = [];
  for (const row of rows) {
    const language = wanted.get(row.id);
    if (!language) continue;
    const translation = saved.find((candidate) => candidate.summaryId === row.id && candidate.language === language);
    if (translation && hasTranslatedTags(row, translation)) {
      readings.set(row.id, { translation, pending: false });
    } else {
      readings.set(row.id, { translation: translation ?? null, pending: true });
      missing.push({ row, language, saved: translation });
    }
  }
  if (missing.length === 0) return readings;
  const ai = options.ai ?? await getAiProvider();
  try {
    await requireFlowcyAccess(viewerId);
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    console.info("[translations] list not translated; showing the originals", error.code);
    for (const { row, saved } of missing) readings.set(row.id, saved ? { translation: saved, pending: false } : ORIGINAL_READING);
    return readings;
  }
  runAfter(async () => {
    let next = 0;
    const worker = async () => {
      while (next < missing.length) {
        const { row, language, saved } = missing[next++];
        await translateCard(db, ai, row, language, new Date(), saved)
          .catch(error => console.warn("[translations] list translation failed", error));
      }
    };
    await Promise.all(Array.from({ length: Math.min(LIST_TRANSLATION_CONCURRENCY, missing.length) }, worker));
  });
  return readings;
}

/**
 * The source document in the language the summary is read in (`language`, null = as written) when
 * its translation is ready; otherwise the original, flagged pending while one is written. The source
 * may be in another language than the chip, so it is translated even when the chip isn't, and not
 * when it is already in the reading language.
 */
export async function readSourceMarkdown(
  db: Database,
  row: SummaryRow,
  viewerId: string | null,
  language: TranslationLanguage | null,
  options: Pick<ReadOptions, "ai"> = {},
): Promise<{ markdown: string; language: string; translationPending: boolean } | null> {
  const original = sourceMarkdownFor(row, viewerId);
  if (original === null) return null;
  const asWritten = { markdown: original, language: sourceLanguageOf(row), translationPending: false };
  const target = language ?? translationLanguageFor(row.language);
  if (!target || translationLanguageFor(sourceLanguageOf(row)) === target) return asWritten;
  const account = translationAccount(row, viewerId);
  const translation = language
    ? (await readSummary(db, row, language, account, options)).translation
    : await readSourceInChipLanguage(db, row, target, account, options.ai);
  if (translation?.contentMarkdown) return { markdown: translation.contentMarkdown, language: translation.language, translationPending: false };
  return { ...asWritten, translationPending: translation?.contentMarkdown === "" };
}

/**
 * The source translated into the chip's own language, kept on a translation row for that language
 * whose card is the original (the chip needs no translation); started in the background like any
 * source translation.
 */
async function readSourceInChipLanguage(
  db: Database,
  row: SummaryRow,
  language: TranslationLanguage,
  account: TranslationAccount,
  ai?: AiProvider,
  now = new Date(),
): Promise<SummaryTranslationRow | null> {
  await db.insert(summaryTranslations).values({
    summaryId: row.id,
    language,
    title: row.title,
    summary: row.summary,
    highlights: row.highlights,
    tags: row.tags,
    contentMarkdown: null,
    headline: null,
    ogImageKey: null,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoNothing();
  const translation = await findTranslation(db, row.id, language);
  if (!translation) return null;
  return startSourceTranslation(db, ai ?? await getAiProvider(), row, translation, account, now);
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

/**
 * The languages a summary has been translated into, in `TRANSLATION_LANGUAGES` order. The row that
 * only holds the source translated into the chip's own `language` isn't a translation of the chip.
 */
export async function listTranslations(db: Database, summaryId: string, language: string | null = null, now = new Date()): Promise<TranslationStatus[]> {
  const original = translationLanguageFor(language);
  const rows = await db.select({
    language: summaryTranslations.language,
    contentMarkdown: summaryTranslations.contentMarkdown,
    updatedAt: summaryTranslations.updatedAt,
  }).from(summaryTranslations).where(eq(summaryTranslations.summaryId, summaryId));
  const order = (language: string) => TRANSLATION_LANGUAGES.indexOf(language as TranslationLanguage);
  return rows.filter((row) => row.language !== original).sort((a, b) => order(a.language) - order(b.language)).map((row) => ({
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
