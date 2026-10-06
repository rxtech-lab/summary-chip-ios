import type { LanguageModelUsage } from "ai";
import { and, eq, sql } from "drizzle-orm";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { TRANSLATION_LANGUAGES, type TranslationLanguage } from "@/lib/contracts/api";
import type { TripDocument } from "@/lib/contracts/trip";
import type { ViewElement, ViewSpec } from "@/lib/contracts/trip-view";
import type { Database } from "@/lib/db/client";
import { summaries, trips, tripTranslations, type SummaryRow, type TripRow, type TripTranslationRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { getTripTranslator } from "@/lib/trips/translator";
import { notifyTripTranslated } from "./notifications";
import { holdTranslation, settleTranslation, type TranslationPayer } from "./translations";

/* ------------------------------------------------------------------------------------------------
 * The texts of a trip
 * ---------------------------------------------------------------------------------------------- */

type Visit = (text: string) => string;

/** Texts without a letter (times, prices, codes) read the same in every language. */
function isTranslatable(text: string): boolean {
  return /\p{L}/u.test(text);
}

function mapViewElement(element: ViewElement, t: Visit): ViewElement {
  const v = <T extends string | number | null | undefined>(value: T): T => (typeof value === "string" ? t(value) : value) as T;
  switch (element.type) {
    case "Card":
      return { ...element, props: { ...element.props, title: v(element.props.title), subtitle: v(element.props.subtitle) } };
    case "Disclosure":
    case "Link":
      return { ...element, props: { ...element.props, title: t(element.props.title) } } as ViewElement;
    case "Heading":
    case "Badge":
      return { ...element, props: { ...element.props, text: t(element.props.text) } } as ViewElement;
    case "Text":
      return { ...element, props: { ...element.props, text: t(element.props.text) } };
    case "Callout":
      return { ...element, props: { ...element.props, title: v(element.props.title), text: t(element.props.text) } };
    case "Stat":
      return { ...element, props: { ...element.props, label: t(element.props.label), value: v(element.props.value), detail: v(element.props.detail) } };
    case "KeyValue":
      return { ...element, props: { ...element.props, items: element.props.items.map((item) => ({ ...item, label: t(item.label), value: v(item.value) })) } };
    case "List":
      return { ...element, props: { ...element.props, items: element.props.items.map(t) } };
    case "Table":
      return {
        ...element,
        props: {
          ...element.props,
          caption: v(element.props.caption),
          totalLabel: v(element.props.totalLabel),
          columns: element.props.columns.map((column) => ({ ...column, label: t(column.label) })),
          rows: element.props.rows.map((row) => ({
            ...row,
            cells: Object.fromEntries(Object.entries(row.cells).map(([key, cell]) => [
              key,
              cell !== null && typeof cell === "object" ? { ...cell, value: v(cell.value), detail: v(cell.detail) } : v(cell),
            ])),
          })),
        },
      };
    case "BarChart":
      return { ...element, props: { ...element.props, title: v(element.props.title), items: element.props.items.map((item) => ({ ...item, label: t(item.label), detail: v(item.detail) })) } };
    case "Image":
      return { ...element, props: { ...element.props, caption: v(element.props.caption) } };
    case "Gallery":
      return { ...element, props: { ...element.props, images: element.props.images.map((image) => ({ ...image, caption: v(image.caption) })) } };
    default:
      return element;
  }
}

function mapViewSpec(spec: ViewSpec, t: Visit): ViewSpec {
  return { ...spec, elements: Object.fromEntries(Object.entries(spec.elements).map(([id, element]) => [id, mapViewElement(element, t)])) };
}

/**
 * The document with every text a reader reads passed through `visit`: titles, names, notes, tips,
 * labels and the texts of custom views. Ids, dates, coordinates, codes, addresses and URLs stay as
 * they are, so a translated document still lines up with the original record by record.
 */
export function mapTripTexts(document: TripDocument, visit: Visit): TripDocument {
  const t: Visit = (text) => (isTranslatable(text) ? visit(text) : text);
  const v = <T extends string | null | undefined>(text: T): T => (text ? t(text) : text) as T;
  return {
    ...document,
    title: t(document.title),
    subtitle: v(document.subtitle),
    intro: v(document.intro),
    places: (document.places ?? []).map((place) => ({
      ...place,
      name: t(place.name),
      note: v(place.note),
      description: v(place.description),
      hours: v(place.hours),
      visitDuration: v(place.visitDuration),
      photos: (place.photos ?? []).map((photo) => ({ ...photo, caption: v(photo.caption) })),
      pricing: (place.pricing ?? []).map((item) => ({ ...item, label: t(item.label), note: v(item.note) })),
    })),
    days: document.days.map((day) => ({
      ...day,
      title: t(day.title),
      short: v(day.short),
      blurb: v(day.blurb),
      tip: v(day.tip),
      route: day.route && { ...day.route, summary: v(day.route.summary) },
      moments: day.moments.map((moment) => ({ ...moment, text: t(moment.text) })),
    })),
    transports: document.transports.map((transport) => ({
      ...transport,
      label: t(transport.label),
      options: transport.options.map((option) => ({
        ...option,
        label: t(option.label),
        duration: v(option.duration),
        warning: v(option.warning),
        notes: option.notes.map(t),
        segments: option.segments.map((segment) => ({
          ...segment,
          fromName: t(segment.fromName),
          toName: t(segment.toName),
          train: segment.train && { ...segment.train, operator: v(segment.train.operator), line: v(segment.train.line), name: v(segment.train.name) },
          flight: segment.flight && { ...segment.flight, airline: v(segment.flight.airline) },
        })),
      })),
    })),
    hotels: document.hotels.map((hotel) => ({ ...hotel, name: t(hotel.name) })),
    expenses: document.expenses.map((expense) => ({ ...expense, title: t(expense.title) })),
    notes: document.notes.map((note) => ({ ...note, title: t(note.title), text: t(note.text) })),
    sources: document.sources.map((source) => ({ ...source, title: t(source.title) })),
    views: (document.views ?? []).map((view) => ({ ...view, title: t(view.title), spec: mapViewSpec(view.spec, t) })),
  };
}

/** Every distinct text of the document that is translated, in reading order. */
export function tripTexts(document: TripDocument): string[] {
  const texts = new Set<string>();
  mapTripTexts(document, (text) => {
    texts.add(text);
    return text;
  });
  return [...texts];
}

/* ------------------------------------------------------------------------------------------------
 * Reading a trip in another language
 * ---------------------------------------------------------------------------------------------- */

/**
 * Missing texts up to this many are translated while the owner waits; more are translated in the
 * background (`workflows/translate-trip.ts`) and the owner is notified when the trip is ready.
 */
export const INLINE_TRIP_TEXTS = 60;
/** A background run that hasn't finished in this long is treated as lost, so a new one can start. */
const TRANSLATING_STALE_MS = 15 * 60_000;
/** Time budget of one background pass; a pass runs as one workflow step (function `maxDuration` 300 s). */
const BACKGROUND_PASS_TIMEOUT_MS = 200_000;

async function findTripTranslation(db: Database, summaryId: string, language: TranslationLanguage) {
  const rows = await db.select().from(tripTranslations)
    .where(and(eq(tripTranslations.summaryId, summaryId), eq(tripTranslations.language, language))).limit(1);
  return rows[0];
}

function isTranslating(row: Pick<TripTranslationRow, "translatingSince"> | undefined, now = Date.now()): boolean {
  return Boolean(row?.translatingSince && now - row.translatingSince.getTime() < TRANSLATING_STALE_MS);
}

function missingTexts(trip: TripRow, strings: Record<string, string>) {
  const texts = tripTexts(trip.document);
  return { texts, missing: texts.filter((text) => !Object.hasOwn(strings, text)) };
}

/**
 * Translates the trip's missing texts on the payer's points and saves the ones that were translated.
 * Throws the points hold's 402/503; `remaining` counts the texts still missing after a failed part.
 */
async function translateMissing(
  db: Database,
  summary: Pick<SummaryRow, "id">,
  trip: TripRow,
  language: TranslationLanguage,
  payer: TranslationPayer,
  saved: TripTranslationRow | undefined,
  options: { ai?: AiProvider; timeoutMs?: number } = {},
): Promise<{ strings: Record<string, string>; remaining: number }> {
  const { texts, missing } = missingTexts(trip, saved?.strings ?? {});
  let strings = saved?.strings ?? {};
  if (missing.length === 0) return { strings, remaining: 0 };
  const ai = options.ai ?? await getAiProvider();
  const charge = await holdTranslation(ai, payer, `${summary.id}:${language}:trip:${trip.revision}`, { summaryId: summary.id, language, part: "trip", texts: missing.length });
  const steps: LanguageModelUsage[] = [];
  let translated: (string | null)[] | null = null;
  try {
    translated = await ai.translateStrings(missing, language, { onUsage: (usage) => steps.push(usage), timeoutMs: options.timeoutMs });
  } finally {
    await settleTranslation(charge, ai, translated !== null, steps, { part: "trip" });
  }
  if (!translated) return { strings, remaining: missing.length };
  // Only the texts the trip still has are kept, so edits don't grow the dictionary forever. Texts
  // whose part failed stay missing, so the next run translates just those.
  const current = new Set(texts);
  strings = Object.fromEntries([
    ...Object.entries(strings).filter(([text]) => current.has(text)),
    ...missing.flatMap((text, index) => {
      const translation = translated[index];
      return translation === null ? [] : [[text, translation.trim() || text]];
    }),
  ]);
  const now = new Date();
  await db.insert(tripTranslations).values({ summaryId: summary.id, language, strings, revision: trip.revision, createdAt: now, updatedAt: now })
    .onConflictDoUpdate({ target: [tripTranslations.summaryId, tripTranslations.language], set: { strings, revision: trip.revision, updatedAt: now } });
  return { strings, remaining: translated.filter((text) => text === null).length };
}

export interface TripReadOptions {
  ai?: AiProvider;
  /** The owner reads it: a large translation runs in the background, and they're notified when it's done. */
  owner?: boolean;
}

export interface TripReading {
  /** The document in the language, null when nothing of it is translated yet. */
  document: TripDocument | null;
  /** A background run is translating the texts still shown as written. */
  translating: boolean;
}

/**
 * The trip's document in `language` (null = as written, returned as null). Texts translated before
 * are reused for free. The texts added or changed since are translated now on the payer's points,
 * or, when the owner reads and there are many, by a background run. The texts not translated
 * (yet) show as written.
 */
export async function readTripDocument(
  db: Database,
  summary: Pick<SummaryRow, "id">,
  trip: TripRow,
  language: TranslationLanguage | null,
  payer: TranslationPayer,
  options: TripReadOptions = {},
): Promise<TripReading> {
  if (!language) return { document: null, translating: false };
  const saved = await findTripTranslation(db, summary.id, language);
  let strings = saved?.strings ?? {};
  const { missing } = missingTexts(trip, strings);
  const reading = (translating: boolean): TripReading => ({
    document: Object.keys(strings).length > 0 ? mapTripTexts(trip.document, (text) => strings[text] ?? text) : null,
    translating,
  });
  if (missing.length === 0) {
    if (saved && saved.revision !== trip.revision) {
      // An edit that only removed or reordered texts: the saved ones still cover the trip.
      await db.update(tripTranslations).set({ revision: trip.revision, updatedAt: new Date() })
        .where(and(eq(tripTranslations.summaryId, summary.id), eq(tripTranslations.language, language)));
    }
    return reading(false);
  }
  if (isTranslating(saved)) return reading(true);
  if (options.owner && missing.length > INLINE_TRIP_TEXTS) {
    await startTripTranslation(db, summary.id, language, payer.userId, await payer.environment?.());
    return reading(true);
  }
  try {
    strings = (await translateMissing(db, summary, trip, language, payer, saved, { ai: options.ai })).strings;
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    console.info("[translations] trip not translated; showing the original", error.code);
  }
  return reading(false);
}

/**
 * The trip in `language` from the texts already translated, without translating anything (the PDF
 * export); texts not translated yet show as written. Null when nothing of it is translated.
 */
export async function savedTripDocument(db: Database, trip: TripRow, language: TranslationLanguage): Promise<TripDocument | null> {
  const strings = (await findTripTranslation(db, trip.summaryId, language))?.strings ?? {};
  return Object.keys(strings).length > 0 ? mapTripTexts(trip.document, (text) => strings[text] ?? text) : null;
}

/**
 * The owner chose to read their trip in `language`. A few missing texts are translated before the
 * choice is saved (`502 TRIP_TRANSLATION_FAILED`, or the points hold's 402/503, when they can't be);
 * more start a background run, and `translating` is true.
 */
export async function translateTrip(
  db: Database,
  summary: Pick<SummaryRow, "id">,
  language: TranslationLanguage | null,
  payer: TranslationPayer,
  ai: AiProvider,
): Promise<{ translating: boolean }> {
  if (!language) return { translating: false };
  const [trip] = await db.select().from(trips).where(eq(trips.summaryId, summary.id)).limit(1);
  if (!trip) return { translating: false };
  const saved = await findTripTranslation(db, summary.id, language);
  const { missing } = missingTexts(trip, saved?.strings ?? {});
  if (missing.length === 0) return { translating: false };
  if (isTranslating(saved)) return { translating: true };
  if (missing.length > INLINE_TRIP_TEXTS) {
    await startTripTranslation(db, summary.id, language, payer.userId, await payer.environment?.());
    return { translating: true };
  }
  const { remaining } = await translateMissing(db, summary, trip, language, payer, saved, { ai });
  if (remaining > 0) throw new ApiError(502, "TRIP_TRANSLATION_FAILED", "The trip could not be translated. Please try again.");
  return { translating: false };
}

/* ------------------------------------------------------------------------------------------------
 * Translating in the background
 * ---------------------------------------------------------------------------------------------- */

/** One background translation: plain data, the input of `workflows/translate-trip.ts`. */
export interface TripTranslationJob {
  summaryId: string;
  language: TranslationLanguage;
  /** The owner, who pays and is notified. */
  userId: string;
  billingEnvironment?: BillingEnvironment;
}

export type TripTranslationOutcome =
  | { status: "done" }
  /** Some parts failed; another pass may finish them. */
  | { status: "partial"; remaining: number }
  /** Nothing more can be done: no points, no trip, or the model failed every part. */
  | { status: "failed"; code: string };

/** Marks the trip as translating and starts the run; a run that can't start is unmarked again. */
async function startTripTranslation(db: Database, summaryId: string, language: TranslationLanguage, userId: string, billingEnvironment?: BillingEnvironment): Promise<void> {
  const now = new Date();
  // A trip never translated before gets an empty dictionary that isn't up to date with any revision.
  await db.insert(tripTranslations).values({ summaryId, language, strings: {}, revision: -1, translatingSince: now, createdAt: now, updatedAt: now })
    .onConflictDoUpdate({ target: [tripTranslations.summaryId, tripTranslations.language], set: { translatingSince: now } });
  try {
    await getTripTranslator().start({ summaryId, language, userId, billingEnvironment });
  } catch (error) {
    await clearTranslating(db, summaryId, language);
    console.error("[translations] background trip translation could not start", error);
    throw new ApiError(503, "TRIP_TRANSLATION_UNAVAILABLE", "The trip could not be translated right now. Please try again.");
  }
}

async function clearTranslating(db: Database, summaryId: string, language: TranslationLanguage): Promise<void> {
  await db.update(tripTranslations).set({ translatingSince: null })
    .where(and(eq(tripTranslations.summaryId, summaryId), eq(tripTranslations.language, language)));
}

/** One pass of a background run: translates what is still missing. Never throws, so the step isn't retried blindly. */
export async function runTripTranslationPass(db: Database, job: TripTranslationJob, options: { ai?: AiProvider } = {}): Promise<TripTranslationOutcome> {
  try {
    const [trip] = await db.select().from(trips).where(eq(trips.summaryId, job.summaryId)).limit(1);
    if (!trip) return { status: "failed", code: "NOT_FOUND" };
    const saved = await findTripTranslation(db, job.summaryId, job.language);
    const payer: TranslationPayer = { userId: job.userId, environment: async () => job.billingEnvironment };
    const { remaining } = await translateMissing(db, { id: job.summaryId }, trip, job.language, payer, saved, { ai: options.ai, timeoutMs: BACKGROUND_PASS_TIMEOUT_MS });
    return remaining === 0 ? { status: "done" } : { status: "partial", remaining };
  } catch (error) {
    if (error instanceof ApiError) return { status: "failed", code: error.code };
    console.error("[translations] background trip translation pass failed", error);
    return { status: "partial", remaining: -1 };
  }
}

/** Ends a background run: unmarks the trip and tells the owner whether it is ready to read. */
export async function finishTripTranslation(db: Database, job: TripTranslationJob, outcome: TripTranslationOutcome): Promise<void> {
  await clearTranslating(db, job.summaryId, job.language);
  const [row] = await db.select({ title: summaries.title, ownerId: summaries.ownerId }).from(summaries).where(eq(summaries.id, job.summaryId)).limit(1);
  if (!row || row.ownerId !== job.userId) return;
  const saved = await findTripTranslation(db, job.summaryId, job.language);
  const title = saved?.strings[row.title] ?? row.title;
  await notifyTripTranslated(db, job.userId, job.summaryId, title, job.language, outcome.status === "done");
}

/** The translations of one trip, for the language picker. */
export interface TripTranslationStatus {
  language: string;
  /** Written for the trip's current revision: switching to it is instant and free. */
  upToDate: boolean;
  /** A background run is translating it. */
  translating: boolean;
}

/** The languages a trip has been (or is being) translated into, in `TRANSLATION_LANGUAGES` order. */
export async function listTripTranslations(db: Database, trip: TripRow): Promise<TripTranslationStatus[]> {
  const rows = await db.select({
    language: tripTranslations.language,
    revision: tripTranslations.revision,
    translatingSince: tripTranslations.translatingSince,
    empty: sql<number>`${tripTranslations.strings} = '{}'`,
  }).from(tripTranslations).where(eq(tripTranslations.summaryId, trip.summaryId));
  const order = (language: string) => TRANSLATION_LANGUAGES.indexOf(language as TranslationLanguage);
  const now = Date.now();
  return rows.sort((a, b) => order(a.language) - order(b.language))
    // A first background run that translated nothing leaves no translation behind.
    .filter((row) => !row.empty || isTranslating(row, now))
    .map((row) => {
      const translating = isTranslating(row, now);
      return { language: row.language, upToDate: !translating && row.revision === trip.revision, translating };
    });
}
