import type { LanguageModelUsage } from "ai";
import { and, eq, sql } from "drizzle-orm";
import type { z } from "zod";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import type { AiProvider } from "@/lib/ai/provider";
import type { TranslationLanguage } from "@/lib/contracts/api";
import { parseOperations, sourceImages } from "@/lib/ai/trip-agent";
import { normalizeDraft, type SummaryDraft } from "@/lib/ai/summary-schema";
import {
  PLANNED_COLLECTIONS,
  tripDocumentSchema,
  type createTripSchema,
  type ingestTripSchema,
  type planSelectionSchema,
  type putTripSchema,
  type TripDocument,
  type TripOperation,
  type tripOperationsRequestSchema,
} from "@/lib/contracts/trip";
import type { Database } from "@/lib/db/client";
import { summaries, tripPlanSelections, trips, type SummaryRow, type TripRow, type Visibility } from "@/lib/db/schema";
import { EXCERPT_LIMIT, SOURCE_TEXT_LIMIT } from "@/lib/extract";
import { runAfter } from "@/lib/http/after";
import { ApiError } from "@/lib/http/errors";
import { reserveTripAgentPoints, settleUsage, type ChatCharge } from "@/lib/subscription/chat-billing";
import { selectCoverTheme } from "./cover-colors";
import { embedSummary, indexSummary } from "./embeddings";
import { syncTripFlights } from "./flights";
import { syncTripWeather } from "./weather";
import { queueTripChangesStatement, startTripNotification } from "./trip-notifications";
import { syncTripReminders } from "./trip-reminders";
import { shareUrlFor } from "./serialize";
import { coverImages, extractSource, findLikedAt, findSummaryById, getOwnedSummary, insertSummary, resolveDeps, type ServiceDeps } from "./summaries";
import { canViewerRead } from "./share-access";
import { applyOperations, tripDayCount, tripDigest, tripText, type PlanSelections } from "./trip-document";
import { listTripTranslations, readTripDocument, savedTripDocument, type TripTranslationStatus } from "./trip-translations";
import { readingLanguage, translationPayer, type BillingEnvironmentResolver } from "./translations";

export type CreateTripInput = z.infer<typeof createTripSchema>;
export type PutTripInput = z.infer<typeof putTripSchema>;
export type TripOperationsInput = z.infer<typeof tripOperationsRequestSchema>;
export type IngestTripInput = z.infer<typeof ingestTripSchema>;
export type PlanSelectionInput = z.infer<typeof planSelectionSchema>;

/** `GET /api/v1/trips/:id`. `id` is the summary's id: the trip is also a library item. */
export interface TripJson {
  id: string;
  slug: string;
  revision: number;
  visibility: Visibility;
  isOwner: boolean;
  createdAt: string;
  /** When the document last changed. */
  updatedAt: string;
  shareUrl: string;
  document: TripDocument;
  /** The language the document's texts are in: a translation's, else `originalLanguage`. */
  language: string;
  /** The language the trip is written in. */
  originalLanguage: string;
  /** Owner only: the language they chose to read it in (`PATCH /api/v1/summaries/:id`); null = as written. */
  displayLanguage: string | null;
  /** `GET` only: when the caller starred the trip (it's listed under Likes); null when they haven't. */
  likedAt?: string | null;
  /**
   * `GET` only: a background run is translating the trip into the language being read; the texts
   * not translated yet show as written, and the owner is notified when it is done.
   */
  translating?: boolean;
  /**
   * `GET` only: the plan options the caller last picked (plan id → option id). Plans without a
   * pick show their `defaultOptionId`, else their first option.
   */
  planSelections?: PlanSelections;
}

/** A trip's document as one viewer reads it, when that is a translation. */
export interface TripTranslationReading {
  document: TripDocument;
  language: TranslationLanguage;
}

/** One row of `GET /api/v1/trips`. */
export interface TripListItem {
  id: string;
  slug: string;
  title: string;
  subtitle: string | null;
  startDate: string;
  endDate: string;
  revision: number;
  updatedAt: string;
  dayCount: number;
  placeCount: number;
}

/** Tags every trip's library item carries. */
const TRIP_TAGS = ["trip"];

function tripNotFound(): ApiError {
  return new ApiError(404, "NOT_FOUND", "The trip does not exist");
}

function revisionConflict(current: number): ApiError {
  return new ApiError(409, "TRIP_REVISION_CONFLICT", `The trip changed since you loaded it (now revision ${current}). Reload it and apply your edit again.`, { revision: current });
}

/** Parses a document after edits; a broken one is `422 TRIP_INVALID` with the issues in `details`. */
function validDocument(document: TripDocument, what = "The edit"): TripDocument {
  const parsed = tripDocumentSchema.safeParse(document);
  if (parsed.success) return parsed.data;
  const issues = parsed.error.issues.map((issue) => ({ path: issue.path, message: issue.message }));
  const listed = issues.slice(0, 3).map((issue) => `${issue.path.join(".") || "document"}: ${issue.message}`).join("; ");
  throw new ApiError(422, "TRIP_INVALID", `${what} leaves the trip invalid: ${listed}`, { issues });
}

export function toTripJson(row: SummaryRow, trip: TripRow, viewerId: string | null, translation: TripTranslationReading | null = null): TripJson {
  const isOwner = viewerId !== null && viewerId === row.ownerId;
  return {
    id: row.id,
    slug: row.slug,
    revision: trip.revision,
    visibility: row.visibility,
    isOwner,
    createdAt: row.createdAt.toISOString(),
    updatedAt: trip.updatedAt.toISOString(),
    shareUrl: shareUrlFor(row.slug),
    document: translation?.document ?? trip.document,
    language: translation?.language ?? row.language,
    originalLanguage: row.language,
    displayLanguage: isOwner ? row.displayLanguage : null,
  };
}

/**
 * Fills the arrays that documents saved before a field existed lack: `views`, and places'
 * `photos` and `pricing`. Everything downstream (the agents, PDF export, the apps) can rely on them.
 */
export function withStoredDefaults(document: TripDocument): TripDocument {
  return {
    ...document,
    places: (document.places ?? []).map((place) => ({ ...place, photos: place.photos ?? [], pricing: place.pricing ?? [] })),
    views: document.views ?? [],
    plans: document.plans ?? [],
  };
}

/** The plan options `userId` picked in a trip, without picks for plans or options that are gone. */
export async function findPlanSelections(db: Database, trip: Pick<TripRow, "summaryId" | "document">, userId: string): Promise<PlanSelections> {
  const rows = await db.select({ selections: tripPlanSelections.selections }).from(tripPlanSelections)
    .where(and(eq(tripPlanSelections.tripId, trip.summaryId), eq(tripPlanSelections.userId, userId))).limit(1);
  const saved = rows[0]?.selections ?? {};
  const plans = new Map((trip.document.plans ?? []).map((plan) => [plan.id, plan]));
  return Object.fromEntries(Object.entries(saved).filter(([planId, optionId]) => plans.get(planId)?.options.some((option) => option.id === optionId)));
}

/**
 * `PUT /api/v1/trips/:id/plan-selections`: anyone who can read the trip picks one option of a plan
 * for themselves (`optionId: null` goes back to the default). The document doesn't change.
 */
export async function selectPlanOption(db: Database, viewerId: string, id: string, input: PlanSelectionInput, now = new Date()): Promise<{ planSelections: PlanSelections }> {
  const found = await findTripForViewer(db, id, viewerId);
  if (!found) throw tripNotFound();
  const plan = found.trip.document.plans.find((item) => item.id === input.planId);
  if (!plan) throw new ApiError(404, "PLAN_NOT_FOUND", `The trip has no plan "${input.planId}"`);
  if (input.optionId !== null && !plan.options.some((option) => option.id === input.optionId)) {
    throw new ApiError(404, "PLAN_OPTION_NOT_FOUND", `Plan "${plan.id}" has no option "${input.optionId}"`);
  }
  const current = await findPlanSelections(db, found.trip, viewerId);
  const selections: PlanSelections = { ...current };
  if (input.optionId === null) delete selections[plan.id];
  else selections[plan.id] = input.optionId;
  await db.insert(tripPlanSelections)
    .values({ tripId: found.trip.summaryId, userId: viewerId, selections, updatedAt: now })
    .onConflictDoUpdate({ target: [tripPlanSelections.tripId, tripPlanSelections.userId], set: { selections, updatedAt: now } });
  return { planSelections: selections };
}

/**
 * A save from an app build from before plans (its document has no `plans` key) keeps the saved
 * plans and puts back the records' `planOptionId`s it dropped, so every alternative stays one.
 */
export function withSavedPlans(document: TripDocument, saved: TripDocument): TripDocument {
  if (!saved.plans?.length) return document;
  const restored: TripDocument = { ...document, plans: saved.plans };
  for (const collection of PLANNED_COLLECTIONS) {
    const options = new Map((saved[collection] as { id: string; planOptionId?: string | null }[]).map((record) => [record.id, record.planOptionId]));
    (restored as Record<string, unknown>)[collection] = (document[collection] as { id: string; planOptionId?: string | null }[])
      .map((record) => (record.planOptionId || !options.get(record.id) ? record : { ...record, planOptionId: options.get(record.id) }));
  }
  return restored;
}

async function findTripRow(db: Database, summaryId: string): Promise<TripRow | undefined> {
  const rows = await db.select().from(trips).where(eq(trips.summaryId, summaryId)).limit(1);
  const row = rows[0];
  return row && { ...row, document: withStoredDefaults(row.document) };
}

/**
 * The trip behind a summary id, for whoever may open the summary (see `share-access.ts`).
 * `viaLink`: already let in through a share link (the website, signed out).
 */
export async function findTripForViewer(db: Database, id: string, viewerId: string | null, viaLink = false): Promise<{ summary: SummaryRow; trip: TripRow } | null> {
  const summary = await findSummaryById(db, id);
  if (!summary || summary.kind !== "trip" || (!viaLink && !await canViewerRead(db, summary, viewerId))) return null;
  const trip = await findTripRow(db, id);
  return trip ? { summary, trip } : null;
}

/** The trip as written (the agents). */
export async function getTrip(db: Database, id: string, viewerId: string): Promise<TripJson> {
  const found = await findTripForViewer(db, id, viewerId);
  if (!found) throw tripNotFound();
  const [likedAt, planSelections] = await Promise.all([findLikedAt(db, viewerId, id), findPlanSelections(db, found.trip, viewerId)]);
  return { ...toTripJson(found.summary, found.trip, viewerId), likedAt: likedAt ? likedAt.toISOString() : null, planSelections };
}

/**
 * `GET /api/v1/trips/:id`: the trip as `viewerId` reads it, like a summary: the owner in the
 * language they chose, anyone else in `accepted` (their `Accept-Language`). Texts not translated
 * yet are translated now on the viewer's points; without points they show as written.
 */
export async function readTripJson(
  db: Database,
  id: string,
  viewerId: string,
  accepted: TranslationLanguage | null,
  options: { ai?: AiProvider; billingEnvironment?: BillingEnvironmentResolver } = {},
): Promise<TripJson> {
  const found = await findTripForViewer(db, id, viewerId);
  if (!found) throw tripNotFound();
  const language = readingLanguage(found.summary, viewerId, accepted);
  const [reading, likedAt, planSelections] = await Promise.all([
    readTripDocument(db, found.summary, found.trip, language, translationPayer(found.summary, viewerId, options.billingEnvironment), {
      ai: options.ai,
      owner: found.summary.ownerId === viewerId,
    }),
    findLikedAt(db, viewerId, id),
    findPlanSelections(db, found.trip, viewerId),
  ]);
  const translation = reading.document && language ? { document: reading.document, language } : null;
  return {
    ...toTripJson(found.summary, found.trip, viewerId, translation),
    likedAt: likedAt ? likedAt.toISOString() : null,
    translating: reading.translating,
    planSelections,
  };
}

/**
 * The trip's document as `viewerId` reads it (like `readTripJson`), from the translations already
 * saved: nothing is translated, so it's free and fast. Texts not translated yet show as written.
 */
export async function readSavedTripDocument(
  db: Database,
  id: string,
  viewerId: string,
  accepted: TranslationLanguage | null,
): Promise<{ document: TripDocument; language: TranslationLanguage | null; planSelections: PlanSelections; originalLanguage: string }> {
  const found = await findTripForViewer(db, id, viewerId);
  if (!found) throw tripNotFound();
  const language = readingLanguage(found.summary, viewerId, accepted);
  const [translated, planSelections] = await Promise.all([
    language ? savedTripDocument(db, found.trip, language) : null,
    findPlanSelections(db, found.trip, viewerId),
  ]);
  const originalLanguage = found.summary.language;
  return translated ? { document: translated, language, planSelections, originalLanguage } : { document: found.trip.document, language: null, planSelections, originalLanguage };
}

/** `{ originalLanguage, items }`: the languages the trip is already translated into. */
export async function getTripTranslations(db: Database, id: string, viewerId: string): Promise<{ originalLanguage: string; items: TripTranslationStatus[] }> {
  const found = await findTripForViewer(db, id, viewerId);
  if (!found) throw tripNotFound();
  return { originalLanguage: found.summary.language, items: await listTripTranslations(db, found.trip) };
}

/** Only the owner edits; others who can see a public trip get 403, everyone else 404. */
export async function getOwnedTrip(db: Database, id: string, ownerId: string): Promise<{ summary: SummaryRow; trip: TripRow }> {
  const summary = await getOwnedSummary(db, id, ownerId).catch((error) => {
    throw error instanceof ApiError && error.code === "NOT_FOUND" ? tripNotFound() : error;
  });
  if (summary.kind !== "trip") throw tripNotFound();
  const trip = await findTripRow(db, id);
  if (!trip) throw tripNotFound();
  return { summary, trip };
}

/* ------------------------------------------------------------------------------------------------
 * Create / list
 * ---------------------------------------------------------------------------------------------- */

/**
 * Saves a new trip: a `kind = "trip"` summary row (title, summary and highlights derived from the
 * document, a designed cover, the trip as plain text for search and embeddings) plus its `trips`
 * row at revision 0. Trips don't count against the summary allowance, and their link never expires.
 */
export async function createTrip(db: Database, principal: ApiPrincipal, input: CreateTripInput, deps?: ServiceDeps): Promise<TripJson> {
  const { ai, store, now } = await resolveDeps(deps);
  const document = input.document;
  const id = crypto.randomUUID();
  const digest = tripDigest(document);
  const text = tripText(document).slice(0, SOURCE_TEXT_LIMIT);

  const language = await ai.detectLanguage(digest) ?? "en";
  const design = await ai.designCover({ title: digest.title, summary: digest.summary, category: "Travel", keywords: digest.keywords, text, language });
  const normalized = normalizeDraft({
    ...digest,
    category: "Travel",
    tags: [],
    language,
    design: design ?? { colors: [], mode: undefined as unknown as "light", emoji: "", accent: "", headline: "" },
  }, { requestedLanguage: "auto", seed: id });
  const draft: SummaryDraft = {
    ...normalized,
    title: digest.title,
    tags: TRIP_TAGS,
    theme: await selectCoverTheme(db, principal.sub, normalized.theme),
  };
  const embedding = embedSummary(ai, { ...draft, siteName: null, sourceTitle: null, contentText: text });

  const createdAt = now();
  const imageKeys = await coverImages(store, ai, id, draft, null, "illustration", createdAt, "trip");
  const tripRow: TripRow = { summaryId: id, document, revision: 0, startDate: document.startDate, endDate: document.endDate, updatedAt: createdAt };
  const row = await insertSummary(db, store, {
    id,
    ownerId: principal.sub,
    kind: "trip",
    sourceType: "text",
    source: "text",
    sourceUrl: null,
    sourceTitle: null,
    siteName: null,
    sourceFileKey: null,
    contentExcerpt: text.slice(0, EXCERPT_LIMIT),
    contentText: text,
    contentMarkdown: null,
    title: draft.title,
    summary: draft.summary,
    highlights: draft.highlights,
    category: draft.category,
    tags: draft.tags,
    keywords: draft.keywords,
    language: draft.language,
    displayLanguage: null,
    theme: draft.theme,
    ogHeadline: draft.headline,
    imageStyle: "illustration",
    ...imageKeys,
    visibility: input.visibility,
    ttlDays: null,
    expiresAt: null,
    viewCount: 0,
    createdAt,
    updatedAt: createdAt,
  }, embedding, () => [db.insert(trips).values(tripRow)]);
  runAfter(() => syncTripFlights(db, id, principal.sub, document));
  runAfter(() => syncTripWeather(db, id, document));
  runAfter(() => syncTripReminders(db, id));
  return toTripJson(row, tripRow, principal.sub);
}

/** The owner's trips: ongoing and upcoming first (soonest start first), then past ones (most recent first). */
export async function listTrips(db: Database, ownerId: string, now = new Date()): Promise<{ trips: TripListItem[] }> {
  const rows = await db.select({ summary: summaries, trip: trips })
    .from(summaries)
    .innerJoin(trips, eq(trips.summaryId, summaries.id))
    .where(and(eq(summaries.ownerId, ownerId), eq(summaries.kind, "trip")));
  const today = now.toISOString().slice(0, 10);
  const items = rows.map(({ summary, trip }): TripListItem => ({
    id: summary.id,
    slug: summary.slug,
    title: trip.document.title,
    subtitle: trip.document.subtitle ?? null,
    startDate: trip.document.startDate,
    endDate: trip.document.endDate,
    revision: trip.revision,
    updatedAt: trip.updatedAt.toISOString(),
    dayCount: trip.document.days.length || tripDayCount(trip.document),
    placeCount: trip.document.places.length,
  }));
  const current = items.filter((item) => item.endDate >= today).sort((a, b) => a.startDate.localeCompare(b.startDate) || a.title.localeCompare(b.title));
  const past = items.filter((item) => item.endDate < today).sort((a, b) => b.endDate.localeCompare(a.endDate) || a.title.localeCompare(b.title));
  return { trips: [...current, ...past] };
}

/* ------------------------------------------------------------------------------------------------
 * Edit
 * ---------------------------------------------------------------------------------------------- */

/**
 * Saves a new document over `trip.revision` (compare-and-swap: a concurrent save makes this one
 * `409 TRIP_REVISION_CONFLICT`), bumps the revision and refreshes the summary row's derived fields.
 * The embedding is recomputed after the response.
 */
async function saveDocument(
  db: Database,
  deps: Pick<ServiceDeps, "ai" | "now">,
  summary: SummaryRow,
  trip: TripRow,
  document: TripDocument,
): Promise<TripJson> {
  const { ai, now } = await resolveDeps(deps);
  if (JSON.stringify(trip.document) === JSON.stringify(document)) return toTripJson(summary, trip, summary.ownerId);
  const updatedAt = now();
  const revision = trip.revision + 1;
  const digest = tripDigest(document);
  const text = tripText(document).slice(0, SOURCE_TEXT_LIMIT);
  const changes = {
    title: digest.title,
    summary: digest.summary,
    highlights: digest.highlights,
    keywords: digest.keywords,
    contentText: text,
    contentExcerpt: text.slice(0, EXCERPT_LIMIT),
    updatedAt,
  } satisfies Partial<SummaryRow>;
  // The save and durable outbox are atomic. SQLite changes() fences both writes to the CAS:
  // a rejected concurrent edit cannot enqueue an alert or overwrite the summary's derived text.
  const [result, queued] = await db.batch([
    db.update(trips)
      .set({ document, revision, startDate: document.startDate, endDate: document.endDate, updatedAt })
      .where(and(eq(trips.summaryId, trip.summaryId), eq(trips.revision, trip.revision))),
    queueTripChangesStatement(db, summary.id, revision, trip.document, document, updatedAt),
    db.update(summaries).set(changes).where(and(eq(summaries.id, summary.id), sql`changes() > 0`)),
  ]);
  if (result.rowsAffected === 0) {
    const current = await findTripRow(db, trip.summaryId);
    if (!current) throw tripNotFound();
    throw revisionConflict(current.revision);
  }
  const batchId = queued.rows[0]?.id;
  if (typeof batchId === "string") runAfter(() => startTripNotification(batchId));
  const updated = { ...summary, ...changes };
  runAfter(() => indexSummary(db, ai, updated));
  // Flights added, changed or removed start or stop being tracked.
  runAfter(() => syncTripFlights(db, summary.id, summary.ownerId, document));
  // So do the trip's weather forecasts (new places, new dates).
  runAfter(() => syncTripWeather(db, summary.id, document));
  runAfter(() => syncTripReminders(db, summary.id));
  return toTripJson(updated, { ...trip, document, revision, startDate: document.startDate, endDate: document.endDate, updatedAt }, summary.ownerId);
}

/** `PUT /api/v1/trips/:id`: the app saves the whole document it edited at `revision`. */
export async function replaceTrip(
  db: Database,
  ownerId: string,
  id: string,
  input: PutTripInput,
  deps: Pick<ServiceDeps, "ai" | "now"> = {},
  /** What the client's document carries: an app build from before `views` or `plans` leaves them out, and the saved ones are kept. */
  sent: { views: boolean; plans: boolean } = { views: true, plans: true },
): Promise<TripJson> {
  const { summary, trip } = await getOwnedTrip(db, id, ownerId);
  if (trip.revision !== input.revision) throw revisionConflict(trip.revision);
  let document = input.document;
  if (!sent.views) document = { ...document, views: trip.document.views };
  if (!sent.plans) document = withSavedPlans(document, trip.document);
  if (!sent.views || !sent.plans) document = validDocument(document, "The save");
  return saveDocument(db, deps, summary, trip, document);
}

/**
 * Applies operations atomically. With `revision`, a trip that changed since is a 409; without it the
 * operations are applied to the latest document (re-applied once if another save lands in between).
 */
export async function applyTripOperations(db: Database, ownerId: string, id: string, input: TripOperationsInput, deps: Pick<ServiceDeps, "ai" | "now"> = {}): Promise<TripJson> {
  for (let attempt = 0; ; attempt += 1) {
    const { summary, trip } = await getOwnedTrip(db, id, ownerId);
    if (input.revision != null && input.revision !== trip.revision) throw revisionConflict(trip.revision);
    const document = validDocument(applyOperations(trip.document, input.operations), "The operations");
    try {
      return await saveDocument(db, deps, summary, trip, document);
    } catch (error) {
      if (input.revision == null && attempt < 2 && error instanceof ApiError && error.code === "TRIP_REVISION_CONFLICT") continue;
      throw error;
    }
  }
}

/**
 * The operations that leave the document valid: all of them when they do together, otherwise each
 * in order that keeps it valid (an operation referencing a record the agent never created is dropped).
 */
export function applicableOperations(document: TripDocument, operations: TripOperation[]): { document: TripDocument; operations: TripOperation[] } {
  const all = tripDocumentSchema.safeParse(applyOperations(document, operations));
  if (all.success) return { document: all.data, operations };
  let current = document;
  const kept: TripOperation[] = [];
  for (const operation of operations) {
    const next = tripDocumentSchema.safeParse(applyOperations(current, [operation]));
    if (!next.success) continue;
    current = next.data;
    kept.push(operation);
  }
  return { document: current, operations: kept };
}

/**
 * The trip chat's edit: the agent's operations applied to the latest document. A set that leaves the
 * trip invalid comes back with its issues so the agent can fix it; with `keepValid` (its last try)
 * the operations that fit are saved and the rest dropped.
 */
export async function applyChatOperations(
  db: Database,
  ownerId: string,
  id: string,
  raw: unknown,
  options: { keepValid: boolean },
  deps: Pick<ServiceDeps, "ai" | "now"> = {},
): Promise<
  | { applied: number; dropped: { index: number; message: string }[]; revision: number }
  | { error: string; issues: { path: string; message: string }[]; dropped: { index: number; message: string }[] }
> {
  const { operations: proposed, rejected } = parseOperations(raw);
  for (let attempt = 0; ; attempt += 1) {
    const latest = await getOwnedTrip(db, id, ownerId);
    const all = tripDocumentSchema.safeParse(applyOperations(latest.trip.document, proposed));
    if (!all.success && !options.keepValid) {
      return {
        error: "The operations leave the trip invalid. Fix them and call updateTrip again with the full list.",
        issues: all.error.issues.slice(0, 12).map((issue) => ({ path: issue.path.join("."), message: issue.message })),
        dropped: rejected,
      };
    }
    const { document, operations } = applicableOperations(latest.trip.document, proposed);
    if (operations.length === 0) return { applied: 0, dropped: rejected, revision: latest.trip.revision };
    try {
      const saved = await saveDocument(db, deps, latest.summary, latest.trip, document);
      return { applied: operations.length, dropped: rejected, revision: saved.revision };
    } catch (error) {
      if (attempt < 2 && error instanceof ApiError && error.code === "TRIP_REVISION_CONFLICT") continue;
      throw error;
    }
  }
}

export interface TripAgentRun {
  trip: TripJson;
  changeSummary: string;
  /** Operations applied (invalid ones the agent proposed are dropped). */
  applied: number;
}

/**
 * Reads the shared source, has the trip agent turn it into operations and saves those that fit.
 * `charge` (held by the caller) is settled at the agent's token cost; a run that never reached the
 * model releases it.
 */
export async function updateTripFromSource(
  db: Database,
  ownerId: string,
  id: string,
  input: IngestTripInput,
  deps: ServiceDeps & { charge: ChatCharge | null },
): Promise<TripAgentRun> {
  const { ai, store } = await resolveDeps(deps);
  const steps: LanguageModelUsage[] = [];
  let outcome = "failed";
  try {
    const { trip } = await getOwnedTrip(db, id, ownerId);
    const { content } = await extractSource(db, ownerId, { source: input.source, followLinks: true }, store, ai);
    const result = await ai.updateTrip({
      document: trip.document,
      source: { text: content.text, title: content.sourceTitle, url: content.sourceUrl, siteName: content.siteName, images: sourceImages(content) },
      instructions: input.instructions,
    }, { onUsage: (usage) => steps.push(usage) });
    if (!result) throw new ApiError(502, "TRIP_AGENT_FAILED", "The trip could not be updated from this source. Please try again.");

    const proposed = parseOperations(result.operations).operations;
    if (content.sourceUrl && !proposed.some((operation) => operation.op === "add_source")) {
      proposed.push({ op: "add_source", source: { title: (content.sourceTitle || content.siteName || content.sourceUrl).slice(0, 300), url: content.sourceUrl } });
    }
    // Saved on the latest revision: the app may have saved while the agent ran.
    for (let attempt = 0; ; attempt += 1) {
      const latest = await getOwnedTrip(db, id, ownerId);
      const { document, operations } = applicableOperations(latest.trip.document, proposed);
      try {
        const saved = operations.length ? await saveDocument(db, deps, latest.summary, latest.trip, document) : toTripJson(latest.summary, latest.trip, ownerId);
        outcome = "finished";
        return { trip: saved, changeSummary: result.changeSummary, applied: operations.length };
      } catch (error) {
        if (attempt < 2 && error instanceof ApiError && error.code === "TRIP_REVISION_CONFLICT") continue;
        throw error;
      }
    }
  } finally {
    if (deps.charge) await settleUsage(deps.charge, ai, steps, { tripId: id, outcome });
  }
}

/**
 * `POST /api/v1/trips/:id/ingest`: points are held now (so an empty balance is a 402 before
 * anything is queued); the agent runs after the response and saves queue a debounced update push.
 */
export async function ingestTrip(
  db: Database,
  principal: ApiPrincipal,
  id: string,
  input: IngestTripInput,
  deps: ServiceDeps = {},
): Promise<{ status: "queued" }> {
  const { ai } = await resolveDeps(deps);
  await getOwnedTrip(db, id, principal.sub);
  const charge = await reserveTripAgentPoints(principal.sub, id, crypto.randomUUID(), ai.chatModelId(), deps.billingEnvironment);
  runAfter(async () => {
    await updateTripFromSource(db, principal.sub, id, input, { ...deps, ai, charge });
  });
  return { status: "queued" };
}

/** MCP `add_to_trip_from_source`: the same agent run, answered when it is done. */
export async function addToTripFromSource(
  db: Database,
  ownerId: string,
  id: string,
  input: IngestTripInput,
  deps: ServiceDeps = {},
): Promise<TripAgentRun> {
  const { ai } = await resolveDeps(deps);
  await getOwnedTrip(db, id, ownerId);
  const charge = await reserveTripAgentPoints(ownerId, id, crypto.randomUUID(), ai.chatModelId(), deps.billingEnvironment);
  return updateTripFromSource(db, ownerId, id, input, { ...deps, ai, charge });
}
