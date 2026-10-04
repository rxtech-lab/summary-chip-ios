import { randomUUID } from "node:crypto";
import type { LanguageModelUsage } from "ai";
import { and, eq, inArray, isNotNull, isNull, lt, or } from "drizzle-orm";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { TRANSLATION_LANGUAGES, type TranslationLanguage } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { summaryTranslations, type SummaryRow, type SummaryTranslationRow } from "@/lib/db/schema";
import { runAfter } from "@/lib/http/after";
import type { ObjectStore } from "@/lib/storage/r2";
import { ApiError } from "@/lib/http/errors";
import { reserveTranslationPoints, settleUsage, type ChatCharge } from "@/lib/subscription/chat-billing";
import type { BillingEnvironment } from "@/lib/subscription/config";
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
 * Billing
 * ---------------------------------------------------------------------------------------------- */

/**
 * Who pays for the translations a read writes: the signed-in reader, else (a visitor on the website
 * or App Clip) the summary's owner. Complete saved translations are shared by every reader and
 * cost nothing to reuse. Missing tag labels (older translations or edited tags) need a new run.
 */
export interface TranslationPayer {
  userId: string;
  environment?: BillingEnvironmentResolver;
}

/**
 * The reader's billing environment, resolved only when a translation is charged: verifying the
 * app's StoreKit proof is too costly for every read.
 */
export type BillingEnvironmentResolver = () => Promise<BillingEnvironment | undefined>;

export function translationPayer(row: Pick<SummaryRow, "ownerId">, viewerId: string | null, environment?: BillingEnvironmentResolver): TranslationPayer {
  return viewerId ? { userId: viewerId, environment } : { userId: row.ownerId };
}

/** Holds points for one translation run; throws `402 TRANSLATION_POINTS_EXHAUSTED` (or 503) before any model call. */
async function holdTranslation(ai: AiProvider, payer: TranslationPayer, run: string, metadata: Record<string, unknown>): Promise<ChatCharge | null> {
  return reserveTranslationPoints(payer.userId, `${run}:${randomUUID()}`, ai.chatModelId(), metadata, await payer.environment?.());
}

/** Charges a run's tokens at the model's API price; a run that delivered nothing releases its hold. */
async function settleTranslation(charge: ChatCharge | null, ai: AiProvider, delivered: boolean, steps: LanguageModelUsage[], metadata: Record<string, unknown> = {}): Promise<void> {
  if (charge) await settleUsage(charge, ai, delivered ? steps : [], { ...metadata, outcome: delivered ? "finished" : "failed" });
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
  onUsage: (usage: LanguageModelUsage) => void,
  now = new Date(),
  saved?: SummaryTranslationRow,
): Promise<SummaryTranslationRow | null> {
  const output = await ai.translateSummary({ title: row.title, summary: row.summary, highlights: row.highlights, tags: row.tags, headline: row.ogHeadline, from: row.language, to: language }, { onUsage });
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
 * The payer's points are held before the run; without them the claim is let go and the original
 * shows. Returns the translation as the caller should serialise it (pending when a run was started).
 */
async function startSourceTranslation(
  db: Database,
  ai: AiProvider,
  row: SummaryRow,
  translation: SummaryTranslationRow,
  payer: TranslationPayer,
  now = new Date(),
): Promise<SummaryTranslationRow> {
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
  const thisRow = and(eq(summaryTranslations.summaryId, row.id), eq(summaryTranslations.language, language));
  let charge: ChatCharge | null;
  try {
    charge = await holdTranslation(ai, payer, `${row.id}:${language}:source`, { summaryId: row.id, language, part: "source" });
  } catch (error) {
    // Let go of the claim so a later read, by someone with points, may translate it.
    await db.update(summaryTranslations).set({ contentMarkdown: null }).where(and(thisRow, eq(summaryTranslations.contentMarkdown, "")));
    if (!(error instanceof ApiError)) throw error;
    console.info("[translations] source document not translated", error.code);
    return { ...translation, contentMarkdown: null };
  }
  runAfter(async () => {
    const steps: LanguageModelUsage[] = [];
    let markdown: string | null = null;
    try {
      markdown = await ai.translateDocument(source, language, { onUsage: (usage) => steps.push(usage) });
    } finally {
      // Never leave the row pending: a failed run becomes null and is retried on a later read.
      await db.update(summaryTranslations).set({ contentMarkdown: markdown || null, updatedAt: new Date() }).where(thisRow);
      await settleTranslation(charge, ai, Boolean(markdown), steps);
    }
  });
  return { ...translation, contentMarkdown: "", updatedAt: now };
}

export interface ReadOptions {
  ai?: AiProvider;
  /**
   * Fail with `502 TRANSLATION_FAILED`, or the points hold's 402/503, instead of falling back to
   * the original text.
   */
  required?: boolean;
}

/**
 * One summary in `language` (null = as written): its saved translation, else one written now on
 * the payer's points. Starts translating the source document in the background when it has one.
 * A failed or unaffordable translation shows the original unless `required`.
 */
export async function readSummary(
  db: Database,
  row: SummaryRow,
  language: TranslationLanguage | null,
  payer: TranslationPayer,
  options: ReadOptions = {},
): Promise<SummaryReading> {
  if (!language) return ORIGINAL_READING;
  const ai = options.ai ?? await getAiProvider();
  let translation: SummaryTranslationRow | null = await findTranslation(db, row.id, language) ?? null;
  if (!translation || !hasTranslatedTags(row, translation)) {
    const saved = translation;
    let charge: ChatCharge | null;
    try {
      charge = await holdTranslation(ai, payer, `${row.id}:${language}`, { summaryId: row.id, language, part: "card" });
    } catch (error) {
      if (options.required || !(error instanceof ApiError)) throw error;
      console.info("[translations] summary not translated; showing the original", error.code);
      return saved ? { translation: saved, pending: false } : ORIGINAL_READING;
    }
    const steps: LanguageModelUsage[] = [];
    let delivered = false;
    try {
      const card = await translateCard(db, ai, row, language, (usage) => steps.push(usage), new Date(), saved ?? undefined);
      delivered = card !== null;
      translation = card ?? (options.required ? null : saved);
    } finally {
      await settleTranslation(charge, ai, delivered, steps);
    }
  }
  if (!translation) {
    if (options.required) throw new ApiError(502, "TRANSLATION_FAILED", "The summary could not be translated. Please try again.");
    return ORIGINAL_READING;
  }
  return { translation: await startSourceTranslation(db, ai, row, translation, payer), pending: false };
}

/** Summaries translated at once in the background for a list page. */
const LIST_TRANSLATION_CONCURRENCY = 4;

/**
 * A page of summaries for one viewer: each in the language they read it in, from saved
 * translations. Missing ones are translated after the response on the viewer's points (one hold
 * for the page) and marked `pending`, so the list returns at once; the client fetches it again to
 * pick them up. Without points they stay in the original language.
 */
export async function readSummaries(
  db: Database,
  rows: SummaryRow[],
  viewerId: string,
  accepted: TranslationLanguage | null,
  options: Pick<ReadOptions, "ai"> & { environment?: BillingEnvironmentResolver } = {},
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
  let charge: ChatCharge | null;
  try {
    charge = await holdTranslation(ai, { userId: viewerId, environment: options.environment }, "list", { summaryIds: missing.map(({ row }) => row.id), part: "card" });
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    console.info("[translations] list not translated; showing the originals", error.code);
    for (const { row, saved } of missing) readings.set(row.id, saved ? { translation: saved, pending: false } : ORIGINAL_READING);
    return readings;
  }
  runAfter(async () => {
    // Only the cards that were saved are charged.
    const steps: LanguageModelUsage[] = [];
    let translated = 0;
    let next = 0;
    const worker = async () => {
      while (next < missing.length) {
        const { row, language, saved } = missing[next++];
        const cardSteps: LanguageModelUsage[] = [];
        const card = await translateCard(db, ai, row, language, (usage) => cardSteps.push(usage), new Date(), saved)
          .catch((error) => { console.warn("[translations] list translation failed", error); return null; });
        if (card) {
          translated++;
          steps.push(...cardSteps);
        }
      }
    };
    try {
      await Promise.all(Array.from({ length: Math.min(LIST_TRANSLATION_CONCURRENCY, missing.length) }, worker));
    } finally {
      await settleTranslation(charge, ai, translated > 0, steps, { translated, requested: missing.length });
    }
  });
  return readings;
}

/** The source document in `language` when its translation is ready; otherwise the original, flagged pending while one is written. */
export async function readSourceMarkdown(
  db: Database,
  row: SummaryRow,
  viewerId: string | null,
  language: TranslationLanguage | null,
  options: Pick<ReadOptions, "ai"> & { environment?: BillingEnvironmentResolver } = {},
): Promise<{ markdown: string; language: string; translationPending: boolean } | null> {
  const original = sourceMarkdownFor(row, viewerId);
  if (original === null) return null;
  const { translation } = await readSummary(db, row, language, translationPayer(row, viewerId, options.environment), options);
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
