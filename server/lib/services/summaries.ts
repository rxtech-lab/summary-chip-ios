import type { LanguageModelUsage } from "ai";
import { and, asc, desc, eq, inArray, isNotNull, lt, ne, or, sql, type SQL } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { linkToFollow } from "@/lib/ai/shared-link";
import { normalizeDraft, type SummaryDraft } from "@/lib/ai/summary-schema";
import { defaultTtlDays, expiresAtFor } from "@/lib/config";
import {
  MAX_UPLOAD_BYTES,
  CATEGORIES,
  type CreateSummaryInput,
  type FacetQuery,
  type ImportSummaryInput,
  type ListQuery,
  type PatchSummaryInput,
} from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { summaries, summaryEmbeddings, summaryTags, summaryViews, uploads, type ImageStyle, type SummaryRow } from "@/lib/db/schema";
import {
  EXCERPT_LIMIT,
  extractFromText,
  extractFromUrl,
  extractFromWebpage,
  hostOf,
  siteNameFor,
  SOURCE_TEXT_LIMIT,
  truncateForModel,
  type ExtractedContent,
} from "@/lib/extract";
import { extractPdfText } from "@/lib/extract/pdf";
import { platformOf } from "@/lib/extract/platforms";
import { runAfter } from "@/lib/http/after";
import { ApiError, notFound } from "@/lib/http/errors";
import { generateOgImages, type OgImages } from "@/lib/og/generate";
import { generateSlug } from "@/lib/slug";
import { reserveDocumentPoints, settleUsage, type ChatCharge } from "@/lib/subscription/chat-billing";
import { consumeSummaryUsage } from "@/lib/subscription/usage";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { artImageKey, getObjectStore, isOwnedUploadKey, OG_CACHE_CONTROL, ogImageKey, type ObjectStore } from "@/lib/storage/r2";
import { embedQuery, embedSummary, indexSummary, saveSummaryEmbedding, type SummaryEmbedding } from "./embeddings";
import { decodeCursor, decodeOffsetCursor, encodeCursor, encodeOffsetCursor, escapeLike, isPublicAndLive, relevance } from "./search";
import { sourceMarkdownFor, toSummaryJson, type SummaryJson } from "./serialize";

export interface ServiceDeps {
  ai?: AiProvider;
  store?: ObjectStore;
  now?: () => Date;
  billingEnvironment?: BillingEnvironment;
}

async function resolveDeps(deps: ServiceDeps = {}) {
  return {
    ai: deps.ai ?? await getAiProvider(),
    store: deps.store ?? getObjectStore(),
    now: deps.now ?? (() => new Date()),
  };
}

/* ------------------------------------------------------------------------------------------------
 * Lookups
 * ---------------------------------------------------------------------------------------------- */

/** Summaries are kept until their owner deletes them; `expiresAt` only ends the public link. */
export async function findSummaryById(db: Database, id: string): Promise<SummaryRow | undefined> {
  const rows = await db.select().from(summaries).where(eq(summaries.id, id)).limit(1);
  return rows[0];
}

export async function findSummaryBySlug(db: Database, slug: string): Promise<SummaryRow | undefined> {
  const rows = await db.select().from(summaries).where(eq(summaries.slug, slug)).limit(1);
  return rows[0];
}

/** Public with a live link, or undefined. Used by the website, OG image and public API. */
export async function findPublicSummaryBySlug(db: Database, slug: string): Promise<SummaryRow | undefined> {
  const rows = await db.select().from(summaries).where(and(eq(summaries.slug, slug), isPublicAndLive())).limit(1);
  return rows[0];
}

/** True when anyone with the link may open the summary: public and its link has not expired. */
export function isLinkLive(row: Pick<SummaryRow, "visibility" | "expiresAt">, now = new Date()): boolean {
  return row.visibility === "public" && (row.expiresAt === null || row.expiresAt > now);
}

/** The owner always; everyone else only while the public link is live. */
export async function findSummaryBySlugForViewer(db: Database, slug: string, viewerId: string | null): Promise<SummaryRow | undefined> {
  const row = await findSummaryBySlug(db, slug);
  if (!row) return undefined;
  if (row.ownerId === viewerId || isLinkLive(row)) return row;
  return undefined;
}

/** Owner sees everything; other signed-in users only summaries with a live public link. */
export async function getSummaryForViewer(db: Database, id: string, viewerId: string): Promise<SummaryRow> {
  const row = await findSummaryById(db, id);
  if (!row || (row.ownerId !== viewerId && !isLinkLive(row))) throw notFound();
  return row;
}

async function getOwnedSummary(db: Database, id: string, ownerId: string): Promise<SummaryRow> {
  const row = await findSummaryById(db, id);
  if (!row) throw notFound();
  if (row.ownerId !== ownerId) {
    if (isLinkLive(row)) throw new ApiError(403, "FORBIDDEN", "Only the owner can change this summary");
    throw notFound();
  }
  return row;
}

/* ------------------------------------------------------------------------------------------------
 * Create
 * ---------------------------------------------------------------------------------------------- */

interface PdfSource {
  content: ExtractedContent;
  uploadKey: string;
}

async function extractPdfUpload(
  db: Database,
  ownerId: string,
  source: Extract<CreateSummaryInput["source"], { type: "pdf" }>,
  store: ObjectStore,
): Promise<PdfSource> {
  if (!isOwnedUploadKey(ownerId, source.uploadKey)) {
    throw new ApiError(403, "UPLOAD_FORBIDDEN", "This upload does not belong to you");
  }
  const [upload] = await db.select().from(uploads)
    .where(and(eq(uploads.key, source.uploadKey), eq(uploads.ownerId, ownerId))).limit(1);
  if (!upload) throw new ApiError(404, "UPLOAD_NOT_FOUND", "The upload does not exist or has expired");
  if (upload.attachedAt) throw new ApiError(409, "UPLOAD_ALREADY_USED", "This upload is already attached to a summary");
  const head = await store.head(source.uploadKey);
  if (!head) throw new ApiError(409, "UPLOAD_INCOMPLETE", "The PDF has not finished uploading");
  if ((head.byteSize ?? 0) > MAX_UPLOAD_BYTES) throw new ApiError(413, "UPLOAD_TOO_LARGE", "PDFs are limited to 25 MB");
  const object = await store.get(source.uploadKey);
  if (object.bytes.byteLength > MAX_UPLOAD_BYTES) throw new ApiError(413, "UPLOAD_TOO_LARGE", "PDFs are limited to 25 MB");
  const pdf = await extractPdfText(object.bytes);
  const filename = (source.filename ?? upload.filename).replace(/\.pdf$/i, "").trim();
  return {
    uploadKey: source.uploadKey,
    content: {
      source: "pdf",
      text: pdf.text,
      sourceUrl: source.sourceUrl ?? null,
      sourceTitle: pdf.title ?? (filename || null),
      siteName: hostOf(source.sourceUrl),
      lang: null,
      imageUrl: null,
    },
  };
}

/**
 * Server-side read failures a web view on the user's device may get past: bot walls, geo blocks,
 * JS-gated pages, and hosts the server refuses to fetch (`URL_NOT_ALLOWED`, e.g. a proxy's fake-IP
 * DNS). The device loads those on its own network and only sends back the page text.
 */
const DEVICE_RETRY_CODES = new Set([
  "SOURCE_HTTP_ERROR",
  "SOURCE_UNREACHABLE",
  "SOURCE_TIMEOUT",
  "URL_UNREACHABLE",
  "URL_NOT_ALLOWED",
  "NO_CONTENT",
]);

function deviceRetryable(error: unknown): error is ApiError {
  return error instanceof ApiError && DEVICE_RETRY_CODES.has(error.code);
}

/** Asks a `deviceReader` client to read the page in its web view and resubmit it as a `webpage` source. */
function needsDevice(url: string, cause: ApiError): ApiError {
  return new ApiError(422, "SOURCE_NEEDS_DEVICE", `The page could not be read on the server (${cause.code}); read it on the device`, {
    url,
    cause: cause.code,
  });
}

/** A URL source: platform extractor, plain fetch and the browser run on the server; the device's web view last. */
async function extractLink(url: string, deviceReader: boolean): Promise<ExtractedContent> {
  try {
    return await extractFromUrl(url);
  } catch (error) {
    if (deviceReader && deviceRetryable(error)) throw needsDevice(url, error);
    throw error;
  }
}

/**
 * Shared text is often a link in disguise ("teaser… https://xhslink.cn/… copy this and open the app").
 * The evaluation model decides; a link is read like a URL source. When the server cannot read it, a
 * `deviceReader` client is asked to read it on the device; other clients get the text summarised.
 */
async function extractSharedText(
  ai: AiProvider,
  source: Extract<CreateSummaryInput["source"], { type: "text" }>,
  options: { deviceReader: boolean; followLinks: boolean },
): Promise<ExtractedContent> {
  const url = options.followLinks ? await linkToFollow(ai, source.text) : null;
  if (url) {
    try {
      return await extractFromUrl(url);
    } catch (error) {
      if (options.deviceReader && deviceRetryable(error)) throw needsDevice(url, error);
      console.warn("[summaries] shared link could not be read; summarising the text instead", error);
    }
  }
  return extractFromText(source);
}

async function extractSource(db: Database, ownerId: string, input: CreateSummaryInput, store: ObjectStore, ai: AiProvider) {
  const source = input.source;
  switch (source.type) {
    case "url":
      return { content: await extractLink(source.url, input.deviceReader === true), uploadKey: null };
    case "webpage":
      return { content: await extractFromWebpage(source), uploadKey: null };
    case "text":
      return { content: await extractSharedText(ai, source, {
        deviceReader: input.deviceReader === true,
        followLinks: input.followLinks !== false,
      }), uploadKey: null };
    case "local":
      return {
        content: { ...extractFromText({ text: source.text, title: source.filename.replace(/\.[^.]+$/, "") }), source: source.kind },
        uploadKey: null,
      };
    case "pdf":
      return extractPdfUpload(db, ownerId, source, store);
  }
}

/** Links, shared pages and text keep their source as Markdown; files from the device only when the owner opts in. */
export function keepsSourceMarkdown(input: CreateSummaryInput): boolean {
  switch (input.source.type) {
    case "url":
    case "webpage":
    case "text":
      return true;
    case "pdf":
      return Boolean(input.source.sourceUrl) || input.keepSourceText === true;
    case "local":
      return input.keepSourceText === true;
  }
}

interface DocumentBilling {
  userId: string;
  summaryId: string;
  environment?: BillingEnvironment;
  /** The summary came out of the free allowance, which then covers its document too. */
  coveredByAllowance: boolean;
}

/**
 * The source as a formatted Markdown document written by the document agent from the page's markup
 * (or its text). Billed like the summary it belongs to: free while the summary came out of the free
 * allowance; past it, points are held first and the agent's tokens charged at the model's API price.
 * Without points, or when the agent fails (charged nothing), the plain text is kept instead —
 * plain text is valid Markdown.
 */
async function sourceDocument(ai: AiProvider, content: ExtractedContent, billing: DocumentBilling): Promise<string | null> {
  const text = content.text.trim();
  if (!text) return null;
  const plain = text.slice(0, SOURCE_TEXT_LIMIT);
  let charge: ChatCharge | null = null;
  try {
    if (!billing.coveredByAllowance) {
      charge = await reserveDocumentPoints(billing.userId, billing.summaryId, ai.chatModelId(), billing.environment);
    }
  } catch (error) {
    console.info("[summaries] source document not formatted; keeping the plain text", error instanceof ApiError ? error.code : error);
    return plain;
  }
  const steps: LanguageModelUsage[] = [];
  const formatted = await ai.formatMarkdown({
    content: content.html || text,
    format: content.html ? "html" : "text",
    title: content.sourceTitle,
    siteName: content.siteName,
    sourceUrl: content.sourceUrl,
    imageUrl: content.imageUrl,
  }, { onUsage: (usage) => steps.push(usage) });
  // Only a delivered document is charged; a failed run releases the hold.
  if (charge) await settleUsage(charge, ai, formatted ? steps : [], { outcome: formatted ? "finished" : "failed" });
  return formatted ? formatted.slice(0, SOURCE_TEXT_LIMIT) : plain;
}

/** Runs after the response: the summary is saved and returned before the document is written. */
async function saveSourceDocument(db: Database, ai: AiProvider, content: ExtractedContent, billing: DocumentBilling): Promise<void> {
  let contentMarkdown: string | null = null;
  try {
    contentMarkdown = await sourceDocument(ai, content, billing);
  } finally {
    // Never leave the row pending: no document becomes "not kept".
    await db.update(summaries).set({ contentMarkdown }).where(eq(summaries.id, billing.summaryId));
  }
}

function isSlugConflict(error: unknown): boolean {
  const text = `${(error as Error)?.message ?? ""} ${String((error as { cause?: unknown })?.cause ?? "")}`;
  return /UNIQUE/i.test(text) && /slug/i.test(text);
}

export function siteLabelFor(row: Pick<SummaryRow, "siteName" | "sourceUrl">): string | null {
  return siteNameFor(row.siteName ?? hostOf(row.sourceUrl), row.sourceUrl);
}

export async function createSummary(
  db: Database,
  principal: ApiPrincipal,
  input: CreateSummaryInput,
  deps?: ServiceDeps,
): Promise<SummaryJson> {
  const { ai, store, now } = await resolveDeps(deps);
  const { content, uploadKey } = await extractSource(db, principal.sub, input, store, ai);
  const id = crypto.randomUUID();
  const usage = await consumeSummaryUsage(principal.sub, id, deps?.billingEnvironment);

  const raw = await ai.summarize({
    text: truncateForModel(content.text),
    title: content.sourceTitle,
    siteName: content.siteName,
    sourceUrl: content.sourceUrl,
    sourceLang: content.lang,
    language: input.language,
  });
  const draft = normalizeDraft(raw, { requestedLanguage: input.language, seed: id, fallbackTitle: content.sourceTitle });
  // A local file's content never leaves this request; the device supplies it again when chatting.
  const storedText = input.source.type === "local" ? "" : content.text;

  // Embedded alongside the image generation; stored once the row exists.
  const embedding = embedSummary(ai, { ...draft, siteName: content.siteName, sourceTitle: content.sourceTitle, contentText: storedText });

  const createdAt = now();
  const imageKeys = await coverImages(store, ai, id, draft, content.siteName ?? hostOf(content.sourceUrl), input.imageStyle, createdAt);

  const ttlDays = input.ttlDays === undefined ? defaultTtlDays() : input.ttlDays;
  const base = {
    id,
    ownerId: principal.sub,
    sourceType: input.source.type,
    source: content.source,
    sourceUrl: content.sourceUrl,
    sourceTitle: content.sourceTitle,
    siteName: content.siteName,
    sourceFileKey: uploadKey,
    contentExcerpt: storedText.slice(0, EXCERPT_LIMIT),
    contentText: storedText.slice(0, SOURCE_TEXT_LIMIT),
    // "" = the document agent is writing it (see `isSourceMarkdownPending`); null = not kept.
    contentMarkdown: keepsSourceMarkdown(input) ? "" : null,
    title: draft.title,
    summary: draft.summary,
    highlights: draft.highlights,
    category: draft.category,
    tags: draft.tags,
    keywords: draft.keywords,
    language: draft.language,
    theme: draft.theme,
    ogHeadline: draft.headline,
    imageStyle: input.imageStyle,
    ...imageKeys,
    visibility: input.visibility,
    ttlDays,
    expiresAt: expiresAtFor(ttlDays, createdAt),
    viewCount: 0,
    createdAt,
    updatedAt: createdAt,
  } satisfies Omit<SummaryRow, "slug">;

  const row = await insertSummary(db, store, base, embedding);
  // The document agent works after the response: free with an allowance summary, else on points.
  if (keepsSourceMarkdown(input)) {
    runAfter(() => saveSourceDocument(db, ai, content, {
      userId: principal.sub,
      summaryId: id,
      environment: deps?.billingEnvironment,
      coveredByAllowance: usage.chargedUnits === 0,
    }));
  }
  return toSummaryJson(row, principal.sub);
}

/**
 * Saves a new summary under a fresh slug (retrying collisions) with its tags, attached upload and
 * embedding. On failure its already-stored images are deleted.
 */
async function insertSummary(
  db: Database,
  store: ObjectStore,
  base: Omit<SummaryRow, "slug">,
  embedding: Promise<SummaryEmbedding | null>,
): Promise<SummaryRow> {
  const uploadKey = base.sourceFileKey;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const row: SummaryRow = { ...base, slug: generateSlug() };
    try {
      const tagRows = row.tags.map((tag) => ({ summaryId: row.id, tag }));
      await db.batch([
        db.insert(summaries).values(row),
        ...(tagRows.length ? [db.insert(summaryTags).values(tagRows).onConflictDoNothing()] : []),
        ...(uploadKey
          ? [db.update(uploads).set({ attachedAt: row.createdAt, summaryId: row.id }).where(eq(uploads.key, uploadKey))]
          : []),
      ]);
      await saveSummaryEmbedding(db, row.id, await embedding);
      return row;
    } catch (error) {
      if (isSlugConflict(error) && attempt < 3) continue;
      await deleteObjects(store, [base.ogImageKey, base.artImageKey]);
      throw error;
    }
  }
  throw new ApiError(500, "SLUG_EXHAUSTED", "Could not allocate a share link");
}

/** Renders and stores the cover; a failed render leaves the summary without images rather than failing it. */
async function coverImages(store: ObjectStore, ai: AiProvider, id: string, draft: SummaryDraft, siteLabel: string | null, imageStyle: ImageStyle, createdAt: Date): Promise<ImageKeys> {
  try {
    const images = await generateOgImages({
      id,
      headline: draft.headline,
      summary: draft.summary,
      category: draft.category,
      keywords: draft.keywords,
      theme: draft.theme,
      siteLabel,
      language: draft.language,
    }, imageStyle, ai);
    return await storeImages(store, id, createdAt.getTime(), images);
  } catch (error) {
    console.error("[summaries] OG image generation failed", error);
    return { ogImageKey: null, artImageKey: null };
  }
}

/**
 * Saves a summary written elsewhere as given — title, summary, tags and the raw source text — in one
 * call. No model summarises it: the server only designs the cover and embeds it for search. The raw
 * text is kept as the source document. Counts as one summary against the caller's allowance.
 */
export async function importSummary(
  db: Database,
  principal: ApiPrincipal,
  input: ImportSummaryInput,
  deps?: ServiceDeps,
): Promise<SummaryJson> {
  const { ai, store, now } = await resolveDeps(deps);
  const id = crypto.randomUUID();
  await consumeSummaryUsage(principal.sub, id, deps?.billingEnvironment);

  // The model's draft shape without a design: the theme falls back to a palette seeded by the id,
  // its mode left unset so it follows that palette's luminance.
  const normalized = normalizeDraft({
    title: input.title,
    summary: input.summary,
    highlights: input.highlights,
    category: input.category,
    tags: [],
    keywords: input.keywords,
    language: input.language,
    design: { colors: [], mode: undefined as unknown as "light", emoji: "", accent: "", headline: "" },
  }, { requestedLanguage: "auto", seed: id });
  const draft: SummaryDraft = { ...normalized, title: input.title, tags: [...new Set(input.tags)] };

  const text = input.text.trim();
  const sourceUrl = input.sourceUrl ?? null;
  const siteName = input.siteName || null;
  const sourceTitle = input.sourceTitle || null;
  const embedding = embedSummary(ai, { ...draft, siteName, sourceTitle, contentText: text });

  const createdAt = now();
  const imageKeys = await coverImages(store, ai, id, draft, siteName ?? hostOf(sourceUrl), input.imageStyle, createdAt);
  const ttlDays = input.ttlDays === undefined ? defaultTtlDays() : input.ttlDays;
  const row = await insertSummary(db, store, {
    id,
    ownerId: principal.sub,
    sourceType: sourceUrl ? "url" : "text",
    source: sourceUrl ? platformOf(sourceUrl) ?? "web" : "text",
    sourceUrl,
    sourceTitle,
    siteName,
    sourceFileKey: null,
    contentExcerpt: text.slice(0, EXCERPT_LIMIT),
    contentText: text.slice(0, SOURCE_TEXT_LIMIT),
    contentMarkdown: text.slice(0, SOURCE_TEXT_LIMIT),
    title: draft.title,
    summary: draft.summary,
    highlights: draft.highlights,
    category: draft.category,
    tags: draft.tags,
    keywords: draft.keywords,
    language: draft.language,
    theme: draft.theme,
    ogHeadline: draft.headline,
    imageStyle: input.imageStyle,
    ...imageKeys,
    visibility: input.visibility,
    ttlDays,
    expiresAt: expiresAtFor(ttlDays, createdAt),
    viewCount: 0,
    createdAt,
    updatedAt: createdAt,
  }, embedding);
  return toSummaryJson(row, principal.sub);
}

/* ------------------------------------------------------------------------------------------------
 * List / facets
 * ---------------------------------------------------------------------------------------------- */

/**
 * The library: the caller's own summaries plus other people's public summaries they opened, as one
 * feed ordered by activity (created for your own, last viewed for others'). `scope` narrows it.
 */
export async function listSummaries(db: Database, userId: string, query: ListQuery, deps: Pick<ServiceDeps, "ai"> = {}) {
  const view = and(eq(summaryViews.summaryId, summaries.id), eq(summaryViews.userId, userId));
  const mine = eq(summaries.ownerId, userId);
  const viewed = and(isNotNull(summaryViews.userId), ne(summaries.ownerId, userId), isPublicAndLive())!;
  const scope = query.scope === "mine" ? mine : query.scope === "viewed" ? viewed : or(mine, viewed)!;
  const activity = sql<number>`(CASE WHEN ${summaries.ownerId} = ${userId} THEN ${summaries.createdAt} ELSE ${summaryViews.viewedAt} END)`;

  const conditions = [scope];
  if (query.category) conditions.push(eq(summaries.category, query.category));
  if (query.visibility) conditions.push(eq(summaries.visibility, query.visibility));
  if (query.source) conditions.push(eq(summaries.source, query.source));
  if (query.tag) {
    conditions.push(inArray(summaries.id, db.select({ id: summaryTags.summaryId }).from(summaryTags).where(eq(summaryTags.tag, query.tag))));
  }
  if (query.q) return searchLibrary(db, userId, { ...query, q: query.q }, conditions, activity, deps);
  const cursor = decodeCursor(query.cursor);
  if (cursor) {
    const at = cursor.time.getTime();
    conditions.push(or(sql`${activity} < ${at}`, and(sql`${activity} = ${at}`, lt(summaries.id, cursor.id)))!);
  }
  const rows = await db.select({ summary: summaries, viewedAt: summaryViews.viewedAt, activity: activity.mapWith(Number) })
    .from(summaries)
    .leftJoin(summaryViews, view)
    .where(and(...conditions))
    .orderBy(desc(activity), desc(summaries.id))
    .limit(query.limit + 1);
  const page = rows.slice(0, query.limit);
  const last = page[page.length - 1];
  return {
    items: page.map((row) => toSummaryJson(row.summary, userId, row.summary.ownerId === userId ? null : row.viewedAt)),
    nextCursor: rows.length > query.limit && last ? encodeCursor(new Date(last.activity), last.summary.id) : null,
  };
}

/**
 * Natural-language library search: matches by meaning (vector distance) or keywords, ranked by
 * relevance, then activity. Paged with an offset cursor since a relevance order has no keyset.
 */
async function searchLibrary(
  db: Database,
  userId: string,
  query: ListQuery & { q: string },
  conditions: SQL[],
  activity: SQL<number>,
  deps: Pick<ServiceDeps, "ai">,
) {
  const offset = decodeOffsetCursor(query.cursor);
  const vector = await embedQuery(deps.ai ?? await getAiProvider(), query.q);
  const match = relevance(query.q, vector);
  const rows = await db.select({ summary: summaries, viewedAt: summaryViews.viewedAt })
    .from(summaries)
    .leftJoin(summaryViews, and(eq(summaryViews.summaryId, summaries.id), eq(summaryViews.userId, userId)))
    .where(and(...conditions, match.where))
    .orderBy(...(match.score ? [asc(match.score)] : []), desc(activity), desc(summaries.id))
    .limit(query.limit + 1)
    .offset(offset);
  const page = rows.slice(0, query.limit);
  return {
    items: page.map((row) => toSummaryJson(row.summary, userId, row.summary.ownerId === userId ? null : row.viewedAt)),
    nextCursor: rows.length > query.limit ? encodeOffsetCursor(offset + query.limit) : null,
  };
}

/** Same universe as the library: own summaries plus viewed public ones. */
function facetUniverse(db: Database, ownerId: string): SQL {
  const viewedIds = db.select({ id: summaryViews.summaryId }).from(summaryViews).where(eq(summaryViews.userId, ownerId));
  return or(eq(summaries.ownerId, ownerId), and(inArray(summaries.id, viewedIds), isPublicAndLive()))!;
}

export async function getFacets(db: Database, ownerId: string) {
  const live = facetUniverse(db, ownerId);
  const count = sql<number>`count(*)`.mapWith(Number);
  const [categories, tags] = await Promise.all([
    db.select({ name: summaries.category, count }).from(summaries).where(live)
      .groupBy(summaries.category).orderBy(desc(count), summaries.category),
    db.select({ name: summaryTags.tag, count }).from(summaryTags)
      .innerJoin(summaries, eq(summaries.id, summaryTags.summaryId))
      .where(live).groupBy(summaryTags.tag).orderBy(desc(count), summaryTags.tag).limit(200),
  ]);
  return { categories, tags };
}

/**
 * One facet list for the filter combobox: names containing `q` (case-insensitive), most used first,
 * paged with an offset cursor. Categories are the closed list, so unused ones come back with count 0.
 */
export async function searchFacets(db: Database, ownerId: string, kind: "category" | "tag", query: FacetQuery) {
  const live = facetUniverse(db, ownerId);
  const offset = decodeOffsetCursor(query.cursor);
  const needle = query.q?.toLowerCase();
  const count = sql<number>`count(*)`.mapWith(Number);
  let items: { name: string; count: number }[];
  let more: boolean;
  if (kind === "category") {
    const rows = await db.select({ name: summaries.category, count }).from(summaries).where(live).groupBy(summaries.category);
    const counts = new Map(rows.map((row) => [row.name, row.count]));
    const all = [...new Set<string>([...CATEGORIES, ...counts.keys()])]
      .filter((name) => !needle || name.toLowerCase().includes(needle))
      .map((name) => ({ name, count: counts.get(name) ?? 0 }))
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
    items = all.slice(offset, offset + query.limit);
    more = all.length > offset + query.limit;
  } else {
    const conditions = [live];
    if (needle) conditions.push(sql`lower(${summaryTags.tag}) LIKE ${`%${escapeLike(needle)}%`} ESCAPE '\\'`);
    const rows = await db.select({ name: summaryTags.tag, count }).from(summaryTags)
      .innerJoin(summaries, eq(summaries.id, summaryTags.summaryId))
      .where(and(...conditions)).groupBy(summaryTags.tag).orderBy(desc(count), summaryTags.tag)
      .limit(query.limit + 1).offset(offset);
    items = rows.slice(0, query.limit);
    more = rows.length > query.limit;
  }
  return { items, nextCursor: more ? encodeOffsetCursor(offset + query.limit) : null };
}

/* ------------------------------------------------------------------------------------------------
 * Update / delete / regenerate
 * ---------------------------------------------------------------------------------------------- */

export async function patchSummary(
  db: Database,
  ownerId: string,
  id: string,
  patch: PatchSummaryInput,
  deps: Pick<ServiceDeps, "ai" | "now" | "store"> = {},
): Promise<SummaryJson> {
  const existing = await getOwnedSummary(db, id, ownerId);
  const now = deps.now?.() ?? new Date();
  const changes: Partial<SummaryRow> = { updatedAt: now };
  if (patch.visibility !== undefined) changes.visibility = patch.visibility;
  // Going private: move the images to fresh random keys so their public CDN URLs stop working.
  let retiredKeys: string[] = [];
  const store = deps.store ?? getObjectStore();
  if (patch.visibility === "private" && existing.visibility === "public") {
    const rotation = await rotateImageKeys(store, existing, now);
    Object.assign(changes, rotation.changes);
    retiredKeys = rotation.retired;
  }
  if (patch.title !== undefined) changes.title = patch.title;
  if (patch.ttlDays !== undefined) {
    changes.ttlDays = patch.ttlDays;
    changes.expiresAt = expiresAtFor(patch.ttlDays, now);
  } else if (patch.visibility === "public" && existing.visibility === "private") {
    // Re-sharing starts a fresh link lifetime instead of reviving an already-expired one.
    changes.expiresAt = expiresAtFor(existing.ttlDays, now);
  }
  let tags: string[] | undefined;
  if (patch.tags !== undefined) {
    tags = [...new Set(patch.tags)].slice(0, 12);
    changes.tags = tags;
  }
  const statements = [
    db.update(summaries).set(changes).where(eq(summaries.id, existing.id)),
    ...(tags !== undefined ? [db.delete(summaryTags).where(eq(summaryTags.summaryId, existing.id))] : []),
    ...(tags?.length ? [db.insert(summaryTags).values(tags.map((tag) => ({ summaryId: existing.id, tag })))] : []),
  ] as const;
  await db.batch(statements as unknown as Parameters<typeof db.batch>[0]);
  await deleteObjects(store, retiredKeys);
  const updated = { ...existing, ...changes };
  if (patch.title !== undefined || patch.tags !== undefined) await indexSummary(db, deps.ai ?? await getAiProvider(), updated);
  return toSummaryJson(updated, ownerId);
}

type ImageKeys = Pick<SummaryRow, "ogImageKey" | "artImageKey">;

/** Uploads the card (and the text-free art when there is one) under fresh keys. */
async function storeImages(store: ObjectStore, id: string, timestamp: number, images: OgImages): Promise<ImageKeys> {
  const ogKey = ogImageKey(id, timestamp);
  await store.put(ogKey, { bytes: images.card, contentType: "image/png", cacheControl: OG_CACHE_CONTROL });
  let artKey: string | null = null;
  if (images.art) {
    artKey = artImageKey(id, timestamp);
    try {
      await store.put(artKey, { bytes: images.art, contentType: "image/png", cacheControl: OG_CACHE_CONTROL });
    } catch (error) {
      console.warn("[summaries] art image upload failed", error);
      artKey = null;
    }
  }
  return { ogImageKey: ogKey, artImageKey: artKey };
}

/** Best-effort deletion of R2 objects that are no longer referenced. */
async function deleteObjects(store: ObjectStore, keys: (string | null)[]): Promise<void> {
  await Promise.all(keys.filter((key): key is string => Boolean(key)).map((key) =>
    store.delete(key).catch((error) => console.warn("[summaries] retired image delete failed", error))));
}

async function copyToFreshKey(store: ObjectStore, from: string, to: string): Promise<string | null> {
  try {
    const object = await store.get(from);
    await store.put(to, { ...object, cacheControl: OG_CACHE_CONTROL });
    return to;
  } catch (error) {
    console.warn("[summaries] image key rotation failed; the old public image URL stays valid", error);
    return null;
  }
}

/**
 * Copies the summary's images to new random keys. `changes` holds the keys that moved; the caller
 * saves them and then deletes `retired`. A copy that failed keeps its old key (and URL).
 */
export async function rotateImageKeys(
  store: ObjectStore,
  row: Pick<SummaryRow, "id"> & ImageKeys,
  now: Date,
): Promise<{ changes: Partial<ImageKeys>; retired: string[] }> {
  const changes: Partial<ImageKeys> = {};
  const retired: string[] = [];
  const [og, art] = await Promise.all([
    row.ogImageKey ? copyToFreshKey(store, row.ogImageKey, ogImageKey(row.id, now.getTime())) : null,
    row.artImageKey ? copyToFreshKey(store, row.artImageKey, artImageKey(row.id, now.getTime())) : null,
  ]);
  if (og && row.ogImageKey) {
    changes.ogImageKey = og;
    retired.push(row.ogImageKey);
  }
  if (art && row.artImageKey) {
    changes.artImageKey = art;
    retired.push(row.artImageKey);
  }
  return { changes, retired };
}

/** Removes a summary row, its dependents and its R2 objects (best effort for objects). */
export async function purgeSummaries(db: Database, store: ObjectStore, rows: Pick<SummaryRow, "id" | "ogImageKey" | "artImageKey" | "sourceFileKey">[]) {
  if (rows.length === 0) return { deleted: 0, objectsDeleted: 0, objectFailures: 0 };
  const ids = rows.map((row) => row.id);
  const fileKeys = rows.map((row) => row.sourceFileKey).filter((key): key is string => Boolean(key));
  await db.batch([
    db.delete(summaryTags).where(inArray(summaryTags.summaryId, ids)),
    db.delete(summaryViews).where(inArray(summaryViews.summaryId, ids)),
    db.delete(summaryEmbeddings).where(inArray(summaryEmbeddings.summaryId, ids)),
    db.delete(summaries).where(inArray(summaries.id, ids)),
    ...(fileKeys.length ? [db.delete(uploads).where(inArray(uploads.key, fileKeys))] : []),
  ]);
  const keys = rows.flatMap((row) => [row.ogImageKey, row.artImageKey, row.sourceFileKey]).filter((key): key is string => Boolean(key));
  const results = await Promise.allSettled(keys.map((key) => store.delete(key)));
  const objectFailures = results.filter((result) => result.status === "rejected").length;
  if (objectFailures) console.warn(`[summaries] ${objectFailures} object deletions failed`);
  return { deleted: ids.length, objectsDeleted: keys.length - objectFailures, objectFailures };
}

export async function deleteSummary(db: Database, ownerId: string, id: string, deps: Pick<ServiceDeps, "store"> = {}): Promise<void> {
  const existing = await getOwnedSummary(db, id, ownerId);
  await purgeSummaries(db, deps.store ?? getObjectStore(), [existing]);
}

export async function regenerateImage(
  db: Database,
  ownerId: string,
  id: string,
  imageStyle: ImageStyle,
  deps?: ServiceDeps,
): Promise<SummaryJson> {
  const { ai, store, now } = await resolveDeps(deps);
  const existing = await getOwnedSummary(db, id, ownerId);
  const updatedAt = now();
  // Never reuse the previous key, even if the clock has not moved.
  const timestamp = Math.max(updatedAt.getTime(), existing.updatedAt.getTime() + 1);
  const images = await generateOgImages({
    id: `${existing.id}-${timestamp}`,
    headline: existing.ogHeadline ?? existing.title,
    summary: existing.summary,
    category: existing.category,
    keywords: existing.keywords,
    theme: existing.theme,
    siteLabel: siteLabelFor(existing),
    language: existing.language,
  }, imageStyle, ai);
  const keys = await storeImages(store, existing.id, timestamp, images);
  const changes = { imageStyle, ...keys, updatedAt: new Date(timestamp) };
  await db.update(summaries).set(changes).where(eq(summaries.id, existing.id));
  await deleteObjects(store, [existing.ogImageKey, existing.artImageKey].filter((key) => key !== keys.ogImageKey && key !== keys.artImageKey));
  return toSummaryJson({ ...existing, ...changes }, ownerId);
}

export async function getSourceMarkdown(db: Database, id: string, viewerId: string): Promise<{ markdown: string }> {
  const markdown = sourceMarkdownFor(await getSummaryForViewer(db, id, viewerId), viewerId);
  if (markdown === null) throw new ApiError(404, "SOURCE_NOT_KEPT", "The source text was not kept for this summary");
  return { markdown };
}

export async function incrementViewCount(db: Database, id: string): Promise<void> {
  await db.update(summaries).set({ viewCount: sql`${summaries.viewCount} + 1` }).where(eq(summaries.id, id));
}
