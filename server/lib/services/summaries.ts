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
  type TranslationLanguage,
} from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { summaries, summaryEmbeddings, summaryLikes, summaryTags, summaryTranslations, summaryViews, trips, uploads, type ImageStyle, type SummaryKind, type SummaryRow } from "@/lib/db/schema";
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
import { findDuplicateChip } from "./duplicates";
import { embedQuery, embedSummary, indexSummary, saveSummaryEmbedding, type SummaryEmbedding } from "./embeddings";
import { decodeCursor, decodeOffsetCursor, encodeCursor, encodeOffsetCursor, escapeLike, relevance } from "./search";
import { toSummaryJson, type SummaryJson } from "./serialize";
import { canViewerRead, findGrantToken, grantTokenSql, isLinkLive, readableByViewer } from "./share-access";
import { listTranslations, readingLanguage, readSourceMarkdown, readSummaries, readSummary, renameTranslation, retireTranslatedCovers, translationLanguageFor, translationPayer, type BillingEnvironmentResolver, type TranslationStatus } from "./translations";
import { translateTrip } from "./trip-translations";
import { notifySummaryAdded } from "./notifications";
import { selectCoverTheme } from "./cover-colors";

export interface ServiceDeps {
  ai?: AiProvider;
  store?: ObjectStore;
  now?: () => Date;
  billingEnvironment?: BillingEnvironment;
}

export async function resolveDeps(deps: ServiceDeps = {}) {
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

export { isLinkLive };

/** Owner sees everything; other signed-in users what a live public link or a share link lets them open. */
export async function getSummaryForViewer(db: Database, id: string, viewerId: string): Promise<SummaryRow> {
  const row = await findSummaryById(db, id);
  if (!row || !await canViewerRead(db, row, viewerId)) throw notFound();
  return row;
}

/**
 * The summary as `viewerId` reads it: the owner in the language they chose, anyone else in
 * `accepted` (their `Accept-Language`), translated now when it hasn't been yet — on the viewer's
 * points, or the owner's for a visitor who isn't signed in.
 */
export async function readSummaryJson(
  db: Database,
  row: SummaryRow,
  viewerId: string | null,
  accepted: TranslationLanguage | null,
  options: {
    ai?: AiProvider;
    viewedAt?: Date | null;
    billingEnvironment?: BillingEnvironmentResolver;
    /** The share link token the viewer opened it with; looked up when not given. */
    grantToken?: string | null;
  } = {},
): Promise<SummaryJson> {
  const payer = translationPayer(row, viewerId, options.billingEnvironment);
  const needsGrant = options.grantToken === undefined && viewerId !== null && row.ownerId !== viewerId && !isLinkLive(row);
  const [reading, likedAt, grantToken] = await Promise.all([
    readSummary(db, row, readingLanguage(row, viewerId, accepted), payer, { ai: options.ai }),
    viewerId ? findLikedAt(db, viewerId, row.id) : null,
    needsGrant ? findGrantToken(db, row.id, viewerId) : options.grantToken ?? null,
  ]);
  return toSummaryJson(row, viewerId, options.viewedAt ?? null, reading, likedAt, grantToken);
}

export async function findLikedAt(db: Database, userId: string, summaryId: string): Promise<Date | null> {
  const [like] = await db.select({ likedAt: summaryLikes.likedAt }).from(summaryLikes)
    .where(and(eq(summaryLikes.userId, userId), eq(summaryLikes.summaryId, summaryId))).limit(1);
  return like?.likedAt ?? null;
}

/**
 * Stars (`liked`) or unstars a summary for `userId`. Anything the caller can read can be starred:
 * their own summaries, or others' while the public link is live. Starring again keeps the first date.
 */
export async function setSummaryLiked(db: Database, userId: string, id: string, liked: boolean): Promise<{ likedAt: string | null }> {
  if (!liked) {
    await db.delete(summaryLikes).where(and(eq(summaryLikes.userId, userId), eq(summaryLikes.summaryId, id)));
    return { likedAt: null };
  }
  await getSummaryForViewer(db, id, userId);
  await db.insert(summaryLikes).values({ userId, summaryId: id }).onConflictDoNothing();
  const likedAt = await findLikedAt(db, userId, id);
  return { likedAt: likedAt ? likedAt.toISOString() : null };
}

export async function getOwnedSummary(db: Database, id: string, ownerId: string): Promise<SummaryRow> {
  const row = await findSummaryById(db, id);
  if (!row) throw notFound();
  if (row.ownerId !== ownerId) {
    if (await canViewerRead(db, row, ownerId)) throw new ApiError(403, "FORBIDDEN", "Only the owner can change this summary");
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

/** Reads a submitted source (link, shared page, text, local file or uploaded PDF) into plain text. Also used by the trip agent. */
export async function extractSource(db: Database, ownerId: string, input: Pick<CreateSummaryInput, "source" | "deviceReader" | "followLinks">, store: ObjectStore, ai: AiProvider) {
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
  const normalized = normalizeDraft(raw, { requestedLanguage: input.language, seed: id, fallbackTitle: content.sourceTitle });
  // The summary's language decides when readers get a translation, so the evaluation model checks
  // what the model reported; a requested language is already known.
  const detected = input.language === "auto" ? await ai.detectLanguage(normalized) : null;
  const draft: SummaryDraft = {
    ...normalized,
    language: detected ?? normalized.language,
    theme: await selectCoverTheme(db, principal.sub, normalized.theme),
  };
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
    kind: "summary",
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
    displayLanguage: null,
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
  runAfter(() => notifySummaryAdded(db, row));
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

type BatchStatement = Parameters<Database["batch"]>[0][number];

/**
 * Saves a new summary under a fresh slug (retrying collisions) with its tags, attached upload,
 * `extra` rows that belong to it (a trip's document) and embedding. On failure its already-stored
 * images are deleted.
 */
export async function insertSummary(
  db: Database,
  store: ObjectStore,
  base: Omit<SummaryRow, "slug">,
  embedding: Promise<SummaryEmbedding | null>,
  extra: () => BatchStatement[] = () => [],
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
        ...extra(),
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
export async function coverImages(store: ObjectStore, ai: AiProvider, id: string, draft: SummaryDraft, siteLabel: string | null, imageStyle: ImageStyle, createdAt: Date, kind: SummaryKind = "summary"): Promise<ImageKeys> {
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
      kind,
    }, imageStyle, ai);
    return await storeImages(store, id, createdAt.getTime(), images);
  } catch (error) {
    console.error("[summaries] OG image generation failed", error);
    return { ogImageKey: null, artImageKey: null };
  }
}

/**
 * Saves a summary written elsewhere as given — title, summary, tags and the raw source text — in one
 * call. No model summarises it: the duplicate agent first checks the caller's library for the same
 * source, title or content (refusing a match with 409 unless `allowDuplicate`), then a model designs
 * the cover theme and artwork, and it is embedded for search. The raw text is kept as the source
 * document. Counts as one summary against the caller's allowance.
 */
export async function importSummary(
  db: Database,
  principal: ApiPrincipal,
  input: ImportSummaryInput,
  /** `free`: not charged to the allowance or points (chips added by the user's MCP agents). */
  deps?: ServiceDeps & { free?: boolean },
): Promise<SummaryJson> {
  const { ai, store, now } = await resolveDeps(deps);
  const text = input.text.trim();
  const sourceUrl = input.sourceUrl ?? null;
  const siteName = input.siteName || null;
  const sourceTitle = input.sourceTitle || null;
  // Checked before the allowance is used, so a refused duplicate costs nothing.
  if (!input.allowDuplicate) {
    const duplicate = await findDuplicateChip(db, ai, principal.sub, { title: input.title, summary: input.summary, sourceUrl, sourceTitle, siteName, text });
    if (duplicate) {
      throw new ApiError(409, "DUPLICATE_SUMMARY", `This looks like a duplicate of "${duplicate.row.title}": ${duplicate.reason}`, {
        reason: duplicate.reason,
        duplicate: toSummaryJson(duplicate.row, principal.sub),
      });
    }
  }
  const id = crypto.randomUUID();
  if (!deps?.free) await consumeSummaryUsage(principal.sub, id, deps?.billingEnvironment);

  // The model designs the headline and emoji; the server assigns the palette below, including
  // when the model fails, so similar topics still get varied colors.
  // The caller's `language` defaults to "en"; the evaluation model checks what the text is really in.
  const language = await ai.detectLanguage({ title: input.title, summary: input.summary, highlights: input.highlights }) ?? input.language;
  const design = await ai.designCover({
    title: input.title,
    summary: input.summary,
    category: input.category,
    keywords: input.keywords,
    text,
    language,
  });
  const normalized = normalizeDraft({
    title: input.title,
    summary: input.summary,
    highlights: input.highlights,
    category: input.category,
    tags: [],
    keywords: input.keywords,
    language,
    design: design ?? { colors: [], mode: undefined as unknown as "light", emoji: "", accent: "", headline: "" },
  }, { requestedLanguage: "auto", seed: id });
  const draft: SummaryDraft = {
    ...normalized,
    title: input.title,
    tags: [...new Set(input.tags)],
    theme: await selectCoverTheme(db, principal.sub, normalized.theme),
  };

  const embedding = embedSummary(ai, { ...draft, siteName, sourceTitle, contentText: text });

  const createdAt = now();
  const imageKeys = await coverImages(store, ai, id, draft, siteName ?? hostOf(sourceUrl), input.imageStyle, createdAt);
  const ttlDays = input.ttlDays === undefined ? defaultTtlDays() : input.ttlDays;
  const row = await insertSummary(db, store, {
    id,
    ownerId: principal.sub,
    kind: "summary",
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
    displayLanguage: null,
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
  runAfter(() => notifySummaryAdded(db, row));
  return toSummaryJson(row, principal.sub);
}

/* ------------------------------------------------------------------------------------------------
 * List / facets
 * ---------------------------------------------------------------------------------------------- */

/**
 * The library: the caller's own summaries plus other people's public summaries they opened, as one
 * feed ordered by activity (created for your own, last viewed for others'). `scope` narrows it.
 */
export interface ListOptions extends Pick<ServiceDeps, "ai"> {
  /** The caller's `Accept-Language`: others' summaries come back translated into it. */
  accepted?: TranslationLanguage | null;
  /** Billing environment of the caller, whose points pay for missing translations. */
  billingEnvironment?: BillingEnvironmentResolver;
}

export async function listSummaries(db: Database, userId: string, query: ListQuery, deps: ListOptions = {}) {
  const view = and(eq(summaryViews.summaryId, summaries.id), eq(summaryViews.userId, userId));
  const mine = eq(summaries.ownerId, userId);
  const viewed = and(isNotNull(summaryViews.userId), ne(summaries.ownerId, userId), readableByViewer(userId))!;
  // Starred summaries stay listed after others' links expire; they come back as `isExpired`.
  const liked = isNotNull(summaryLikes.userId);
  const scope = query.scope === "mine" ? mine
    : query.scope === "viewed" ? viewed
    : query.scope === "liked" ? liked
    : or(mine, viewed)!;
  // Likes are ordered by when they were starred; everything else by created (own) or last viewed (others').
  const activity = query.scope === "liked"
    ? sql<number>`${summaryLikes.likedAt}`
    : sql<number>`(CASE WHEN ${summaries.ownerId} = ${userId} THEN ${summaries.createdAt} ELSE ${summaryViews.viewedAt} END)`;

  const conditions = [scope];
  if (query.category) conditions.push(eq(summaries.category, query.category));
  if (query.visibility) conditions.push(eq(summaries.visibility, query.visibility));
  if (query.source) conditions.push(eq(summaries.source, query.source));
  if (query.kind) conditions.push(eq(summaries.kind, query.kind));
  if (query.tag) {
    conditions.push(inArray(summaries.id, db.select({ id: summaryTags.summaryId }).from(summaryTags).where(eq(summaryTags.tag, query.tag))));
  }
  if (query.q) return searchLibrary(db, userId, { ...query, q: query.q }, conditions, activity, deps);
  const cursor = decodeCursor(query.cursor);
  if (cursor) {
    const at = cursor.time.getTime();
    conditions.push(or(sql`${activity} < ${at}`, and(sql`${activity} = ${at}`, lt(summaries.id, cursor.id)))!);
  }
  const rows = await db.select({ summary: summaries, viewedAt: summaryViews.viewedAt, likedAt: summaryLikes.likedAt, grant: grantTokenSql(userId), activity: activity.mapWith(Number) })
    .from(summaries)
    .leftJoin(summaryViews, view)
    .leftJoin(summaryLikes, likeOf(userId))
    .where(and(...conditions))
    .orderBy(desc(activity), desc(summaries.id))
    .limit(query.limit + 1);
  const page = rows.slice(0, query.limit);
  const last = page[page.length - 1];
  const readings = await readSummaries(db, readable(page, userId), userId, deps.accepted ?? null, { ai: deps.ai, environment: deps.billingEnvironment });
  return {
    items: page.map((row) => toSummaryJson(row.summary, userId, row.summary.ownerId === userId ? null : row.viewedAt, readings.get(row.summary.id), row.likedAt, row.grant)),
    nextCursor: rows.length > query.limit && last ? encodeCursor(new Date(last.activity), last.summary.id) : null,
  };
}

/** Rows the caller may still read; expired likes are sent without their text, so they aren't translated. */
function readable(page: { summary: SummaryRow; grant: string | null }[], userId: string): SummaryRow[] {
  return page.filter((row) => row.summary.ownerId === userId || row.grant !== null || isLinkLive(row.summary)).map((row) => row.summary);
}

function likeOf(userId: string): SQL {
  return and(eq(summaryLikes.summaryId, summaries.id), eq(summaryLikes.userId, userId))!;
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
  deps: ListOptions,
) {
  const offset = decodeOffsetCursor(query.cursor);
  const vector = await embedQuery(deps.ai ?? await getAiProvider(), query.q);
  const match = relevance(query.q, vector);
  const rows = await db.select({ summary: summaries, viewedAt: summaryViews.viewedAt, likedAt: summaryLikes.likedAt, grant: grantTokenSql(userId) })
    .from(summaries)
    .leftJoin(summaryViews, and(eq(summaryViews.summaryId, summaries.id), eq(summaryViews.userId, userId)))
    .leftJoin(summaryLikes, likeOf(userId))
    .where(and(...conditions, match.where))
    .orderBy(...(match.score ? [asc(match.score)] : []), desc(activity), desc(summaries.id))
    .limit(query.limit + 1)
    .offset(offset);
  const page = rows.slice(0, query.limit);
  const readings = await readSummaries(db, readable(page, userId), userId, deps.accepted ?? null, { ai: deps.ai, environment: deps.billingEnvironment });
  return {
    items: page.map((row) => toSummaryJson(row.summary, userId, row.summary.ownerId === userId ? null : row.viewedAt, readings.get(row.summary.id), row.likedAt, row.grant)),
    nextCursor: rows.length > query.limit ? encodeOffsetCursor(offset + query.limit) : null,
  };
}

/** Same universe as the library: own summaries plus viewed ones the caller may still open. */
function facetUniverse(db: Database, ownerId: string): SQL {
  const viewedIds = db.select({ id: summaryViews.summaryId }).from(summaryViews).where(eq(summaryViews.userId, ownerId));
  return or(eq(summaries.ownerId, ownerId), and(inArray(summaries.id, viewedIds), readableByViewer(ownerId)))!;
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
  /** `asWritten`: the edit is to the text as written, never to the translation the owner reads (agents). */
  deps: Pick<ServiceDeps, "ai" | "now" | "store"> & { billingEnvironment?: BillingEnvironmentResolver; asWritten?: boolean } = {},
): Promise<SummaryJson> {
  const existing = await getOwnedSummary(db, id, ownerId);
  const now = deps.now?.() ?? new Date();
  const changes: Partial<SummaryRow> = { updatedAt: now };
  if (patch.summary !== undefined) changes.summary = patch.summary;
  if (patch.highlights !== undefined) changes.highlights = patch.highlights;
  if (patch.category !== undefined) changes.category = patch.category;
  if (patch.keywords !== undefined) changes.keywords = [...new Set(patch.keywords)];
  if (patch.title !== undefined && deps.asWritten) changes.title = patch.title;
  // Translations of the old text would read stale: dropped, and re-made from the new text on the next read.
  const textChanged = (changes.summary !== undefined && changes.summary !== existing.summary)
    || (changes.highlights !== undefined && JSON.stringify(changes.highlights) !== JSON.stringify(existing.highlights))
    || (changes.title !== undefined && changes.title !== existing.title);
  const store = deps.store ?? getObjectStore();
  if (textChanged) {
    await retireTranslatedCovers(db, store, [existing.id]);
    await db.delete(summaryTranslations).where(eq(summaryTranslations.summaryId, existing.id));
  }
  if (patch.displayLanguage !== undefined) {
    // Reading it as written is stored as null, so a later edit of the original shows through.
    const language = patch.displayLanguage;
    changes.displayLanguage = language && translationLanguageFor(existing.language) !== language ? language : null;
  }
  // Translated (on the owner's points) before anything is saved: a language that could not be translated is not stored.
  const ai = deps.ai ?? await getAiProvider();
  const language = readingLanguage({ ...existing, ...changes }, ownerId, null);
  const reading = await readSummary(db, { ...existing, ...changes }, language, translationPayer(existing, ownerId, deps.billingEnvironment), {
    ai,
    required: patch.displayLanguage !== undefined,
  });
  // A trip switches its whole diary: a few texts are translated now, so the trip opens in that
  // language at once; a large trip is translated in the background and the owner is notified.
  if (existing.kind === "trip" && patch.displayLanguage !== undefined) await translateTrip(db, existing, language, translationPayer(existing, ownerId, deps.billingEnvironment), ai);
  // The owner edits the title they are reading: a translation's, or the original's.
  let renamedTranslation = false;
  if (patch.title !== undefined && !deps.asWritten && reading.translation && language) {
    renamedTranslation = await renameTranslation(db, existing.id, language, patch.title, now);
    if (renamedTranslation) reading.translation = { ...reading.translation, title: patch.title, updatedAt: now };
  }
  if (patch.title !== undefined && !renamedTranslation) changes.title = patch.title;
  if (patch.visibility !== undefined) changes.visibility = patch.visibility;
  // Going private: move the images to fresh random keys so their public CDN URLs stop working.
  let retiredKeys: string[] = [];
  if (patch.visibility === "private" && existing.visibility === "public") {
    const rotation = await rotateImageKeys(store, existing, now);
    Object.assign(changes, rotation.changes);
    retiredKeys = rotation.retired;
  }
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
  const tagsChanged = tags !== undefined && JSON.stringify(tags) !== JSON.stringify(existing.tags);
  const statements = [
    db.update(summaries).set(changes).where(eq(summaries.id, existing.id)),
    ...(tags !== undefined ? [db.delete(summaryTags).where(eq(summaryTags.summaryId, existing.id))] : []),
    ...(tags?.length ? [db.insert(summaryTags).values(tags.map((tag) => ({ summaryId: existing.id, tag })))] : []),
    ...(tagsChanged ? [db.update(summaryTranslations).set({ tags: null }).where(eq(summaryTranslations.summaryId, existing.id))] : []),
  ] as const;
  await db.batch(statements as unknown as Parameters<typeof db.batch>[0]);
  await deleteObjects(store, retiredKeys);
  if (retiredKeys.length) await retireTranslatedCovers(db, store, [existing.id]);
  const updated = { ...existing, ...changes };
  if (changes.title !== undefined || patch.tags !== undefined || patch.summary !== undefined || patch.highlights !== undefined
    || patch.category !== undefined || patch.keywords !== undefined) await indexSummary(db, ai, updated);
  if (tagsChanged && reading.translation) return readSummaryJson(db, updated, ownerId, null, { ai, billingEnvironment: deps.billingEnvironment });
  return toSummaryJson(updated, ownerId, null, reading);
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
  await retireTranslatedCovers(db, store, ids);
  await db.batch([
    db.delete(summaryTags).where(inArray(summaryTags.summaryId, ids)),
    db.delete(summaryViews).where(inArray(summaryViews.summaryId, ids)),
    db.delete(summaryLikes).where(inArray(summaryLikes.summaryId, ids)),
    db.delete(summaryEmbeddings).where(inArray(summaryEmbeddings.summaryId, ids)),
    db.delete(summaryTranslations).where(inArray(summaryTranslations.summaryId, ids)),
    db.delete(trips).where(inArray(trips.summaryId, ids)),
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
  const theme = await selectCoverTheme(db, ownerId, existing.theme);
  const images = await generateOgImages({
    id: `${existing.id}-${timestamp}`,
    headline: existing.ogHeadline ?? existing.title,
    summary: existing.summary,
    category: existing.category,
    keywords: existing.keywords,
    theme,
    siteLabel: siteLabelFor(existing),
    language: existing.language,
    kind: existing.kind,
  }, imageStyle, ai);
  const keys = await storeImages(store, existing.id, timestamp, images);
  const changes = { imageStyle, theme, ...keys, updatedAt: new Date(timestamp) };
  await db.update(summaries).set(changes).where(eq(summaries.id, existing.id));
  await deleteObjects(store, [existing.ogImageKey, existing.artImageKey].filter((key) => key !== keys.ogImageKey && key !== keys.artImageKey));
  await retireTranslatedCovers(db, store, [existing.id]);
  return readSummaryJson(db, { ...existing, ...changes }, ownerId, null, { ai });
}

/**
 * The source document in the language the viewer reads the summary in once its translation is
 * written; until then the original, with `translationPending`.
 */
export async function getSourceMarkdown(
  db: Database,
  id: string,
  viewerId: string,
  accepted: TranslationLanguage | null = null,
  deps: Pick<ServiceDeps, "ai"> & { billingEnvironment?: BillingEnvironmentResolver } = {},
): Promise<{ markdown: string; language: string; translationPending: boolean }> {
  const row = await getSummaryForViewer(db, id, viewerId);
  const source = await readSourceMarkdown(db, row, viewerId, readingLanguage(row, viewerId, accepted), { ai: deps.ai, environment: deps.billingEnvironment });
  if (source === null) throw new ApiError(404, "SOURCE_NOT_KEPT", "The source text was not kept for this summary");
  return source;
}

export async function incrementViewCount(db: Database, id: string): Promise<void> {
  await db.update(summaries).set({ viewCount: sql`${summaries.viewCount} + 1` }).where(eq(summaries.id, id));
}

/** `{ originalLanguage, items }`: the languages the summary is already translated into (owner, or anyone who may open it). */
export async function getTranslations(db: Database, id: string, viewerId: string): Promise<{ originalLanguage: string; items: TranslationStatus[] }> {
  const row = await getSummaryForViewer(db, id, viewerId);
  return { originalLanguage: row.language, items: await listTranslations(db, row.id) };
}
