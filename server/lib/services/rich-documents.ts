import { and, eq, sql } from "drizzle-orm";
import type { z } from "zod";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { normalizeDraft, type SummaryDraft } from "@/lib/ai/summary-schema";
import {
  richDocumentSchema,
  type createRichDocumentSchema,
  type RichBlock,
  type RichDocument,
  type RichDocumentOperation,
  type richDocumentOperationsRequestSchema,
} from "@/lib/contracts/rich-document";
import type { Database } from "@/lib/db/client";
import { richDocuments, summaries, type RichDocumentRow, type SummaryRow, type Visibility } from "@/lib/db/schema";
import { EXCERPT_LIMIT, SOURCE_TEXT_LIMIT } from "@/lib/extract";
import { runAfter } from "@/lib/http/after";
import { ApiError } from "@/lib/http/errors";
import { blockIdAllocator, documentToMarkdown, markdownToBlocks, plainText } from "@/lib/rich-document/markdown";
import { selectCoverTheme } from "./cover-colors";
import { versionStatements, type VersionOptions } from "./document-versions";
import { embedSummary, indexSummary } from "./embeddings";
import { shareUrlFor } from "./serialize";
import { canViewerRead } from "./share-access";
import { coverImages, findSummaryById, getOwnedSummary, insertSummary, resolveDeps, type ServiceDeps } from "./summaries";

export type CreateRichDocumentInput = z.infer<typeof createRichDocumentSchema>;
export type RichDocumentOperationsInput = z.infer<typeof richDocumentOperationsRequestSchema>;
type SaveDeps = Pick<ServiceDeps, "ai" | "now" | "store"> & VersionOptions;

/** `GET /api/v1/rich-documents/:id`. */
export interface RichDocumentJson {
  id: string;
  slug: string;
  revision: number;
  visibility: Visibility;
  isOwner: boolean;
  createdAt: string;
  updatedAt: string;
  shareUrl: string;
  document: RichDocument;
}

/** One row of `GET /api/v1/rich-documents`. */
export interface RichDocumentListItem {
  id: string;
  slug: string;
  title: string;
  revision: number;
  updatedAt: string;
  blockCount: number;
}

const RICH_DOCUMENT_TAGS = ["document"];

function documentNotFound(): ApiError {
  return new ApiError(404, "NOT_FOUND", "The document does not exist");
}

function revisionConflict(current: number): ApiError {
  return new ApiError(409, "RICH_DOCUMENT_REVISION_CONFLICT", `The document changed since you loaded it (now revision ${current}). Reload it and apply your edit again.`, { revision: current });
}

function invalid(message: string, issues: { path: string[]; message: string }[]): ApiError {
  return new ApiError(422, "RICH_DOCUMENT_INVALID", message, { issues });
}

/** Parses a document after edits; a broken one is `422 RICH_DOCUMENT_INVALID` with the issues in `details`. */
export function validRichDocument(document: unknown, what = "The edit"): RichDocument {
  const parsed = richDocumentSchema.safeParse(document);
  if (parsed.success) return parsed.data;
  const issues = parsed.error.issues.map((issue) => ({ path: issue.path.map(String), message: issue.message }));
  const listed = issues.slice(0, 3).map((issue) => `${issue.path.join(".") || "document"}: ${issue.message}`).join("; ");
  throw invalid(`${what} leaves the document invalid: ${listed}`, issues);
}

/* ------------------------------------------------------------------------------------------------
 * Derived text
 * ---------------------------------------------------------------------------------------------- */

function clip(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}

/** The document as plain text: what the card, search and embeddings read. */
export function richDocumentText(document: RichDocument): string {
  return [document.title, document.description ?? "", plainText(documentToMarkdown(document, { includeTitle: false }))].filter(Boolean).join("\n");
}

/** The library card's text: the description or the opening text, and the section headings. */
export function richDocumentDigest(document: RichDocument): { title: string; summary: string; highlights: string[]; keywords: string[] } {
  const markdown = document.blocks.filter((block) => block.type === "text").flatMap((block) => block.columns.map((column) => column.markdown ?? "")).join("\n\n");
  const headings = [...markdown.matchAll(/^#{1,3}\s+(.+?)\s*#*\s*$/gm)].map((match) => plainText(match[1])).filter(Boolean);
  const body = plainText(markdown.replace(/^#{1,6}\s+.*$/gm, ""));
  const media = document.blocks.filter((block) => block.type !== "text").length;
  const fallback = body || `A document of ${document.blocks.length} block${document.blocks.length === 1 ? "" : "s"}${media ? `, ${media} with media` : ""}.`;
  return {
    title: clip(document.title, 200),
    summary: clip(document.description || fallback.replace(/\s+/g, " "), 1200),
    highlights: [...new Set(headings)].slice(0, 5).map((heading) => clip(heading, 300)),
    keywords: [...new Set(headings)].slice(0, 10).map((heading) => heading.slice(0, 60)),
  };
}

/* ------------------------------------------------------------------------------------------------
 * Read
 * ---------------------------------------------------------------------------------------------- */

export function toRichDocumentJson(row: SummaryRow, stored: RichDocumentRow, viewerId: string | null): RichDocumentJson {
  return {
    id: row.id,
    slug: row.slug,
    revision: stored.revision,
    visibility: row.visibility,
    isOwner: viewerId !== null && viewerId === row.ownerId,
    createdAt: row.createdAt.toISOString(),
    updatedAt: stored.updatedAt.toISOString(),
    shareUrl: shareUrlFor(row.slug),
    document: stored.document,
  };
}

export async function findRichDocumentRow(db: Database, id: string): Promise<RichDocumentRow | null> {
  const [row] = await db.select().from(richDocuments).where(eq(richDocuments.summaryId, id)).limit(1);
  return row ?? null;
}

export async function getRichDocument(db: Database, id: string, viewerId: string): Promise<RichDocumentJson> {
  const summary = await findSummaryById(db, id);
  if (!summary || summary.kind !== "rich_document" || !await canViewerRead(db, summary, viewerId)) throw documentNotFound();
  const stored = await findRichDocumentRow(db, id);
  if (!stored) throw documentNotFound();
  return toRichDocumentJson(summary, stored, viewerId);
}

/** Only the owner edits. */
export async function getOwnedRichDocument(db: Database, id: string, ownerId: string): Promise<{ summary: SummaryRow; stored: RichDocumentRow }> {
  const summary = await getOwnedSummary(db, id, ownerId).catch((error) => {
    throw error instanceof ApiError && error.code === "NOT_FOUND" ? documentNotFound() : error;
  });
  if (summary.kind !== "rich_document") throw documentNotFound();
  const stored = await findRichDocumentRow(db, id);
  if (!stored) throw documentNotFound();
  return { summary, stored };
}

/** The owner's documents, most recently changed first. */
export async function listRichDocuments(db: Database, ownerId: string): Promise<{ documents: RichDocumentListItem[] }> {
  const rows = await db.select({ summary: summaries, stored: richDocuments })
    .from(summaries)
    .innerJoin(richDocuments, eq(richDocuments.summaryId, summaries.id))
    .where(and(eq(summaries.ownerId, ownerId), eq(summaries.kind, "rich_document")));
  const items = rows.map(({ summary, stored }): RichDocumentListItem => ({
    id: summary.id,
    slug: summary.slug,
    title: stored.document.title,
    revision: stored.revision,
    updatedAt: stored.updatedAt.toISOString(),
    blockCount: stored.document.blocks.length,
  }));
  return { documents: items.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)) };
}

/* ------------------------------------------------------------------------------------------------
 * Create
 * ---------------------------------------------------------------------------------------------- */

/** The document a create request describes: as given, or built from its Markdown. */
export function documentFromCreateInput(input: CreateRichDocumentInput): RichDocument {
  if (input.document) return input.document;
  const parsed = markdownToBlocks(input.markdown ?? "", { takeTitle: !input.title });
  const title = input.title ?? parsed.title;
  if (!title) throw invalid("Give a title, or start the Markdown with a # heading", [{ path: ["title"], message: "required" }]);
  return validRichDocument({ title, description: input.description ?? null, blocks: parsed.blocks }, "The Markdown");
}

/**
 * Saves a new document: a `kind = "rich_document"` summary row (card text derived from the blocks, a
 * designed cover, the text for search) plus its `rich_documents` row at revision 0. Free, and its link
 * never expires.
 */
export async function createRichDocument(db: Database, principal: ApiPrincipal, input: CreateRichDocumentInput, deps?: ServiceDeps & VersionOptions): Promise<RichDocumentJson> {
  const { ai, store, now } = await resolveDeps(deps);
  const document = documentFromCreateInput(input);
  const id = crypto.randomUUID();
  const digest = richDocumentDigest(document);
  const text = richDocumentText(document).slice(0, SOURCE_TEXT_LIMIT);

  const language = await ai.detectLanguage(digest) ?? "en";
  const design = await ai.designCover({ title: digest.title, summary: digest.summary, category: "Other", keywords: digest.keywords, text, language });
  const normalized = normalizeDraft({
    ...digest,
    category: "Other",
    tags: [],
    language,
    design: design ?? { colors: [], mode: undefined as unknown as "light", emoji: "", accent: "", headline: "" },
  }, { requestedLanguage: "auto", seed: id });
  const draft: SummaryDraft = {
    ...normalized,
    title: digest.title,
    tags: RICH_DOCUMENT_TAGS,
    theme: await selectCoverTheme(db, principal.sub, normalized.theme),
  };
  const embedding = embedSummary(ai, { ...draft, siteName: null, sourceTitle: null, contentText: text });

  const createdAt = now();
  const imageKeys = await coverImages(store, ai, id, draft, null, "illustration", createdAt, "rich_document");
  const stored: RichDocumentRow = { summaryId: id, document, revision: 0, updatedAt: createdAt };
  const row = await insertSummary(db, store, {
    id,
    ownerId: principal.sub,
    kind: "rich_document",
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
    sourceLanguage: null,
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
  }, embedding, () => [db.insert(richDocuments).values(stored)], document, { actor: deps?.actor });
  return toRichDocumentJson(row, stored, principal.sub);
}

/* ------------------------------------------------------------------------------------------------
 * Edit
 * ---------------------------------------------------------------------------------------------- */

function missingBlock(id: string): ApiError {
  return invalid(`There is no block "${id}" in the document`, [{ path: ["blocks", id], message: "not found" }]);
}

/** Puts blocks after `after` (first for null, last when undefined). */
function insertedAt(blocks: RichBlock[], inserted: RichBlock[], after: string | null | undefined): RichBlock[] {
  if (after === undefined) return [...blocks, ...inserted];
  if (after === null) return [...inserted, ...blocks];
  const index = blocks.findIndex((block) => block.id === after);
  if (index < 0) throw missingBlock(after);
  return [...blocks.slice(0, index + 1), ...inserted, ...blocks.slice(index + 1)];
}

/** Applies one operation; the whole document is validated once the batch is applied. */
export function applyRichDocumentOperation(document: RichDocument, operation: RichDocumentOperation): RichDocument {
  switch (operation.op) {
    case "set_meta":
      return {
        ...document,
        ...(operation.title !== undefined ? { title: operation.title } : {}),
        ...(operation.description !== undefined ? { description: operation.description } : {}),
      };
    case "upsert_block": {
      const index = document.blocks.findIndex((block) => block.id === operation.block.id);
      if (index >= 0 && operation.after === undefined) {
        return { ...document, blocks: document.blocks.map((block, at) => (at === index ? operation.block : block)) };
      }
      if (operation.after === operation.block.id) throw invalid("A block can't go after itself", [{ path: ["after"], message: "is the block itself" }]);
      const rest = document.blocks.filter((block) => block.id !== operation.block.id);
      return { ...document, blocks: insertedAt(rest, [operation.block], operation.after) };
    }
    case "update_block": {
      const block = document.blocks.find((candidate) => candidate.id === operation.id);
      if (!block) throw missingBlock(operation.id);
      const changes = Object.fromEntries(Object.entries(operation.changes).filter(([, value]) => value !== undefined));
      const updated = { ...block, ...changes } as RichBlock;
      return { ...document, blocks: document.blocks.map((candidate) => (candidate.id === operation.id ? updated : candidate)) };
    }
    case "move_block": {
      const block = document.blocks.find((candidate) => candidate.id === operation.id);
      if (!block) throw missingBlock(operation.id);
      if (operation.after === operation.id) throw invalid("A block can't go after itself", [{ path: ["after"], message: "is the block itself" }]);
      return { ...document, blocks: insertedAt(document.blocks.filter((candidate) => candidate.id !== operation.id), [block], operation.after) };
    }
    case "delete_block":
      if (!document.blocks.some((block) => block.id === operation.id)) throw missingBlock(operation.id);
      return { ...document, blocks: document.blocks.filter((block) => block.id !== operation.id) };
    case "insert_markdown": {
      const { blocks } = markdownToBlocks(operation.markdown, { nextId: blockIdAllocator(document.blocks.map((block) => block.id)) });
      return { ...document, blocks: insertedAt(document.blocks, blocks, operation.after) };
    }
    case "replace_markdown":
      return { ...document, blocks: markdownToBlocks(operation.markdown).blocks };
  }
}

export function applyRichDocumentOperations(document: RichDocument, operations: RichDocumentOperation[]): RichDocument {
  return validRichDocument(operations.reduce(applyRichDocumentOperation, document));
}

/**
 * Saves a document over `stored.revision` (compare-and-swap: a concurrent save makes this one
 * `409 RICH_DOCUMENT_REVISION_CONFLICT`), refreshes the card's derived text and adds a version.
 */
async function saveRichDocument(db: Database, deps: SaveDeps, summary: SummaryRow, stored: RichDocumentRow, document: RichDocument): Promise<RichDocumentJson> {
  const { ai, now } = await resolveDeps(deps);
  if (JSON.stringify(stored.document) === JSON.stringify(document)) return toRichDocumentJson(summary, stored, summary.ownerId);
  const updatedAt = now();
  const revision = stored.revision + 1;
  const digest = richDocumentDigest(document);
  const text = richDocumentText(document).slice(0, SOURCE_TEXT_LIMIT);
  const changes = {
    title: digest.title,
    summary: digest.summary,
    highlights: digest.highlights,
    keywords: digest.keywords,
    contentText: text,
    contentExcerpt: text.slice(0, EXCERPT_LIMIT),
    updatedAt,
  } satisfies Partial<SummaryRow>;
  // `changes()` fences the writes to the compare-and-swap: a refused save touches nothing else.
  const [result] = await db.batch([
    db.update(richDocuments).set({ document, revision, updatedAt }).where(and(eq(richDocuments.summaryId, stored.summaryId), eq(richDocuments.revision, stored.revision))),
    db.update(summaries).set(changes).where(and(eq(summaries.id, summary.id), sql`changes() > 0`)),
    ...versionStatements(db, summary, document, { at: updatedAt, actor: deps.actor, restoredFrom: deps.restoredFrom, fenced: true }),
  ]);
  if (result.rowsAffected === 0) {
    const current = await findRichDocumentRow(db, stored.summaryId);
    if (!current) throw documentNotFound();
    throw revisionConflict(current.revision);
  }
  const updated = { ...summary, ...changes };
  runAfter(() => indexSummary(db, ai, updated));
  return toRichDocumentJson(updated, { ...stored, document, revision, updatedAt }, summary.ownerId);
}

/**
 * Applies operations as one change. With `revision` a stale edit is refused; without it, the edit
 * goes on the latest document and retries when another save lands in between.
 */
export async function editRichDocument(db: Database, ownerId: string, id: string, input: RichDocumentOperationsInput, deps: SaveDeps = {}): Promise<RichDocumentJson> {
  for (let attempt = 0; ; attempt += 1) {
    const { summary, stored } = await getOwnedRichDocument(db, id, ownerId);
    if (input.revision !== undefined && input.revision !== stored.revision) throw revisionConflict(stored.revision);
    const document = applyRichDocumentOperations(stored.document, input.operations);
    try {
      return await saveRichDocument(db, deps, summary, stored, document);
    } catch (error) {
      if (input.revision === undefined && attempt < 2 && error instanceof ApiError && error.code === "RICH_DOCUMENT_REVISION_CONFLICT") continue;
      throw error;
    }
  }
}

/** Brings a version back as a new one, over the latest revision. */
export async function restoreRichDocument(db: Database, ownerId: string, id: string, content: unknown, deps: SaveDeps): Promise<RichDocumentJson> {
  const document = validRichDocument(content, "Restoring this version");
  for (let attempt = 0; ; attempt += 1) {
    const { summary, stored } = await getOwnedRichDocument(db, id, ownerId);
    try {
      return await saveRichDocument(db, deps, summary, stored, document);
    } catch (error) {
      if (attempt < 2 && error instanceof ApiError && error.code === "RICH_DOCUMENT_REVISION_CONFLICT") continue;
      throw error;
    }
  }
}
