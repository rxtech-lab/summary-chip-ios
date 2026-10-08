import { and, desc, eq, sql } from "drizzle-orm";
import type { z } from "zod";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { normalizeDraft, type SummaryDraft } from "@/lib/ai/summary-schema";
import type { createPaperSchema, PaperDocument, PaperOperation, PaperReference, putPaperSchema } from "@/lib/contracts/paper";
import type { Database } from "@/lib/db/client";
import { documentVersions, papers, summaries, type PaperRow, type SummaryRow, type Visibility } from "@/lib/db/schema";
import { EXCERPT_LIMIT, SOURCE_TEXT_LIMIT } from "@/lib/extract";
import { runAfter } from "@/lib/http/after";
import { ApiError } from "@/lib/http/errors";
import { getLatexCompiler, LatexCompilerError, type LatexIssue, type LatexResult } from "@/lib/latex/compiler";
import type { ObjectStore } from "@/lib/storage/r2";
import { selectCoverTheme } from "./cover-colors";
import { paperContent, versionStatements, type VersionContentByKind, type VersionOptions } from "./document-versions";
import { embedSummary, indexSummary } from "./embeddings";
import { applyPaperOperations, latexTitle, paperDigest, paperHash, paperText, samePaper, templateFiles, validPaper } from "./paper-document";
import { paperAssetBytes, paperAssetStatements, preparePaperAssets } from "./paper-assets";
import { queuePaperChangesStatement, startPaperNotification } from "./paper-notifications";
import { checkReferencesLater, checkReferencesNow, claimReferences, referenceQuietMs, referenceStatuses, type ReferenceCheckDeps } from "./paper-references";
import { shareUrlFor } from "./serialize";
import { canViewerRead } from "./share-access";
import { coverImages, findLikedAt, findSummaryById, getOwnedSummary, insertSummary, resolveDeps, type ServiceDeps } from "./summaries";
import { readPaperDocument } from "./paper-translations";
import { paperRenderingSchema, type PaperRendering } from "@/lib/contracts/paper-rendering";
import { renderLatex } from "@/lib/latex/rendering";

export type CreatePaperInput = z.infer<typeof createPaperSchema>;
export type PutPaperInput = z.infer<typeof putPaperSchema>;
/**
 * How a save checks the bibliography entries it added or changed: `later` after the response,
 * once typing has paused (the app's autosave); `now` before answering, so an agent hears about
 * reference errors in the same call.
 */
export interface ReferenceCheckOptions {
  referenceChecks?: "later" | "now";
  /** `later` only: how long the bibliography must stay put first. */
  referenceQuietMs?: number;
  /** Tests: opens a reference's link instead of the network. */
  openLink?: ReferenceCheckDeps["openLink"];
}

/** What a save needs: the model, store and clock, who is saving (for a version it adds), and how references are checked. */
export type PaperSaveDeps = Pick<ServiceDeps, "ai" | "now" | "store"> & VersionOptions & ReferenceCheckOptions;

/** `GET /api/v1/papers/:id`. `id` is the summary's id: the paper is also a library item. */
export interface PaperJson {
  id: string;
  slug: string;
  /** Counts saves of the working copy (autosaves, agent edits, restores). */
  revision: number;
  visibility: Visibility;
  isOwner: boolean;
  createdAt: string;
  updatedAt: string;
  shareUrl: string;
  title: string;
  files: PaperDocument["files"];
  mainFile: string;
  compiler: PaperDocument["compiler"];
  /** The newest saved version; null only for papers whose history was trimmed away. */
  version: number | null;
  /** The working copy has manual edits not saved as a version yet (they are when the editor closes). */
  hasUnversionedChanges: boolean;
  /** The bibliography entries with their checks (owner only; empty for others). */
  references: PaperReference[];
  /** `GET` only: when the caller starred the paper; null when they haven't. */
  likedAt?: string | null;
  originalLanguage: string;
  language: string;
  displayLanguage: string | null;
  translationOutdated: boolean;
  renderingOptions: PaperRendering;
}

/** One row of `GET /api/v1/papers`. */
export interface PaperListItem {
  id: string;
  slug: string;
  title: string;
  mainFile: string;
  fileCount: number;
  revision: number;
  updatedAt: string;
}

/** A compile that produced no PDF: `422 LATEX_COMPILE_FAILED` with the errors in `details`. */
export interface PaperCompileFailure {
  errors: LatexIssue[];
  log: string;
}

const PAPER_TAGS = ["paper"];

function paperNotFound(): ApiError {
  return new ApiError(404, "NOT_FOUND", "The paper does not exist");
}

function revisionConflict(current: number): ApiError {
  return new ApiError(409, "PAPER_REVISION_CONFLICT", `The paper changed since you loaded it (now revision ${current}). Reload it and apply your edit again.`, { revision: current });
}

function compileFailed(failure: PaperCompileFailure): ApiError {
  const first = failure.errors[0];
  const where = first?.file ? ` (${first.file}${first.line ? `:${first.line}` : ""})` : "";
  return new ApiError(422, "LATEX_COMPILE_FAILED", `LaTeX could not compile the paper: ${first?.message ?? "no PDF was produced"}${where}`, failure);
}

function documentOf(summary: SummaryRow, paper: PaperRow): PaperDocument {
  return { title: summary.title, files: paper.files, mainFile: paper.mainFile, compiler: paper.compiler };
}

async function latestVersionNumber(db: Database, summaryId: string): Promise<number | null> {
  const [row] = await db.select({ version: sql<number | null>`max(${documentVersions.version})` }).from(documentVersions).where(eq(documentVersions.summaryId, summaryId));
  return row?.version ?? null;
}

export function toPaperJson(summary: SummaryRow, paper: PaperRow, viewerId: string | null, version: number | null, references: PaperReference[] = []): PaperJson {
  const isOwner = viewerId !== null && viewerId === summary.ownerId;
  return {
    id: summary.id,
    slug: summary.slug,
    revision: paper.revision,
    visibility: summary.visibility,
    isOwner,
    createdAt: summary.createdAt.toISOString(),
    updatedAt: paper.updatedAt.toISOString(),
    shareUrl: shareUrlFor(summary.slug),
    title: summary.title,
    files: paper.files,
    mainFile: paper.mainFile,
    compiler: paper.compiler,
    version,
    hasUnversionedChanges: isOwner && paper.revision > paper.versionedRevision,
    references: isOwner ? references : [],
    originalLanguage: summary.language,
    language: summary.language,
    displayLanguage: isOwner ? summary.displayLanguage : null,
    translationOutdated: false,
    renderingOptions: paperRenderingSchema.parse(paper.renderingOptions),
  };
}

/** The paper as JSON with its version and, for the owner, its references' checks. */
async function paperJson(db: Database, summary: SummaryRow, paper: PaperRow, viewerId: string | null): Promise<PaperJson> {
  const isOwner = viewerId !== null && viewerId === summary.ownerId;
  const [version, references] = await Promise.all([
    latestVersionNumber(db, summary.id),
    isOwner ? referenceStatuses(db, summary.id, documentOf(summary, paper)) : Promise.resolve([]),
  ]);
  return toPaperJson(summary, paper, viewerId, version, references);
}

/**
 * Claims the bibliography entries `document` added or changed since they were last checked, and
 * checks them as `options` says (see `ReferenceCheckOptions`).
 */
async function checkReferences(db: Database, summaryId: string, document: PaperDocument, deps: ReferenceCheckDeps, options: ReferenceCheckOptions): Promise<void> {
  // The save already landed: a failed claim leaves the entries unchecked for the next save.
  const claimed = await claimReferences(db, summaryId, document, deps.now()).catch((error: unknown) => {
    console.warn("[papers] reference checks not started", error);
    return [];
  });
  const checkDeps = { ...deps, openLink: options.openLink ?? deps.openLink };
  if (options.referenceChecks === "now") await checkReferencesNow(db, summaryId, claimed, checkDeps);
  else checkReferencesLater(db, summaryId, document.title, claimed, checkDeps, options.referenceQuietMs ?? referenceQuietMs());
}

async function findPaperRow(db: Database, summaryId: string): Promise<PaperRow | undefined> {
  const rows = await db.select().from(papers).where(eq(papers.summaryId, summaryId)).limit(1);
  return rows[0];
}

/** The paper behind a summary id, for whoever may open the summary (see `share-access.ts`). */
export async function findPaperForViewer(db: Database, id: string, viewerId: string | null, viaLink = false): Promise<{ summary: SummaryRow; paper: PaperRow } | null> {
  const summary = await findSummaryById(db, id);
  if (!summary || summary.kind !== "paper" || (!viaLink && !await canViewerRead(db, summary, viewerId))) return null;
  const paper = await findPaperRow(db, id);
  return paper ? { summary, paper } : null;
}

/** Only the owner edits; others who can see a public paper get 403, everyone else 404. */
export async function getOwnedPaper(db: Database, id: string, ownerId: string): Promise<{ summary: SummaryRow; paper: PaperRow }> {
  const summary = await getOwnedSummary(db, id, ownerId).catch((error) => {
    throw error instanceof ApiError && error.code === "NOT_FOUND" ? paperNotFound() : error;
  });
  if (summary.kind !== "paper") throw paperNotFound();
  const paper = await findPaperRow(db, id);
  if (!paper) throw paperNotFound();
  return { summary, paper };
}

/** `GET /api/v1/papers/:id`: the owner, or anyone signed in who may open it (read-only). */
export async function getPaper(db: Database, id: string, viewerId: string, options?: { language?: string | null }): Promise<PaperJson> {
  const found = await findPaperForViewer(db, id, viewerId);
  if (!found) throw paperNotFound();
  const [likedAt, json] = await Promise.all([findLikedAt(db, viewerId, id), paperJson(db, found.summary, found.paper, viewerId)]);
  if (options) {
    const reading = await readPaperDocument(db, found.summary, found.paper, viewerId, options);
    return { ...json, ...reading.document, language: reading.language, translationOutdated: reading.outdated, likedAt: likedAt ? likedAt.toISOString() : null };
  }
  return { ...json, likedAt: likedAt ? likedAt.toISOString() : null };
}

/* ------------------------------------------------------------------------------------------------
 * Create / list
 * ---------------------------------------------------------------------------------------------- */

/**
 * Saves a new paper: a `kind = "paper"` summary row (title, abstract and section titles derived from
 * the source, a designed cover, the text for search) plus its `papers` row, as version 1.
 * Papers don't count against the summary allowance, and their link never expires.
 */
export async function createPaper(db: Database, principal: ApiPrincipal, input: CreatePaperInput, deps: ServiceDeps & VersionOptions & ReferenceCheckOptions = {}): Promise<PaperJson> {
  const { ai, store, now } = await resolveDeps(deps);
  const id = crypto.randomUUID();
  const fallbackTitle = input.title ?? "Untitled Paper";
  const project = input.files
    ? { files: input.files, mainFile: input.mainFile ?? input.files.find((file) => file.path === "main.tex")?.path ?? input.files.find((file) => file.path.endsWith(".tex"))?.path ?? input.files[0].path }
    : templateFiles(input.template ?? "article", fallbackTitle);
  const document = await preparePaperAssets(db, store, principal.sub, id, validPaper({
    title: input.title ?? latexTitle(project.files, project.mainFile) ?? fallbackTitle,
    files: project.files,
    mainFile: project.mainFile,
    compiler: input.compiler ?? "pdflatex",
  }, "The new paper"));
  const digest = paperDigest(document);
  const text = paperText(document).slice(0, SOURCE_TEXT_LIMIT);

  const language = await ai.detectLanguage(digest) ?? "en";
  const design = await ai.designCover({ title: digest.title, summary: digest.summary, category: "Research", keywords: digest.keywords, text, language });
  const normalized = normalizeDraft({
    ...digest,
    category: "Research",
    tags: [],
    language,
    design: design ?? { colors: [], mode: undefined as unknown as "light", emoji: "", accent: "", headline: "" },
  }, { requestedLanguage: "auto", seed: id });
  const draft: SummaryDraft = {
    ...normalized,
    title: digest.title,
    summary: digest.summary,
    highlights: digest.highlights,
    tags: PAPER_TAGS,
    theme: await selectCoverTheme(db, principal.sub, normalized.theme),
  };
  const embedding = embedSummary(ai, { ...draft, siteName: null, sourceTitle: null, contentText: text });

  const createdAt = now();
  const imageKeys = await coverImages(store, ai, id, draft, null, "illustration", createdAt, "paper");
  const paperRow: PaperRow = {
    summaryId: id,
    files: document.files,
    mainFile: document.mainFile,
    compiler: document.compiler,
    revision: 0,
    versionedRevision: 0,
    pdfHash: null,
    pdfKey: null,
    renderingOptions: {},
    updatedAt: createdAt,
  };
  const row = await insertSummary(db, store, {
    id,
    ownerId: principal.sub,
    kind: "paper",
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
  }, embedding, () => [
    db.insert(papers).values(paperRow),
    ...paperAssetStatements(db, id, document, createdAt),
    queuePaperChangesStatement(db, id, paperRow.revision, createdAt, true),
  ], paperContent(document), { actor: deps.actor });
  // Debounced: an agent usually fills a paper in with edits right after creating it.
  runAfter(() => startPaperNotification(id).catch(() => console.warn("[papers] notification not started")));
  await checkReferences(db, id, document, { ai, now }, { referenceQuietMs: 0, ...deps });
  return paperJson(db, row, paperRow, principal.sub);
}

/** The owner's papers, most recently edited first. */
export async function listPapers(db: Database, ownerId: string): Promise<{ papers: PaperListItem[] }> {
  const rows = await db.select({ summary: summaries, paper: papers })
    .from(summaries)
    .innerJoin(papers, eq(papers.summaryId, summaries.id))
    .where(and(eq(summaries.ownerId, ownerId), eq(summaries.kind, "paper")))
    .orderBy(desc(papers.updatedAt));
  return {
    papers: rows.map(({ summary, paper }) => ({
      id: summary.id,
      slug: summary.slug,
      title: summary.title,
      mainFile: paper.mainFile,
      fileCount: paper.files.length,
      revision: paper.revision,
      updatedAt: paper.updatedAt.toISOString(),
    })),
  };
}

/* ------------------------------------------------------------------------------------------------
 * Save
 * ---------------------------------------------------------------------------------------------- */

/**
 * Saves `document` over `paper.revision` (compare-and-swap: a concurrent save makes this one
 * `409 PAPER_REVISION_CONFLICT`), bumps the revision and refreshes the summary row's derived
 * fields. With `version`, the save is also the paper's next version (atomically). The embedding is
 * recomputed after the response.
 */
async function savePaper(
  db: Database,
  deps: PaperSaveDeps,
  summary: SummaryRow,
  paper: PaperRow,
  document: PaperDocument,
  options: { version: boolean },
): Promise<PaperJson> {
  const { ai, now, store } = await resolveDeps(deps);
  document = await preparePaperAssets(db, store, summary.ownerId, summary.id, document, paper.files);
  const updatedAt = now();
  const revision = paper.revision + 1;
  const digest = paperDigest(document);
  const text = paperText(document).slice(0, SOURCE_TEXT_LIMIT);
  const changes = {
    title: digest.title,
    summary: digest.summary,
    highlights: digest.highlights,
    keywords: digest.keywords,
    contentText: text,
    contentExcerpt: text.slice(0, EXCERPT_LIMIT),
    updatedAt,
  } satisfies Partial<SummaryRow>;
  const saved = {
    files: document.files,
    mainFile: document.mainFile,
    compiler: document.compiler,
    revision,
    versionedRevision: options.version ? revision : paper.versionedRevision,
    updatedAt,
  } satisfies Partial<PaperRow>;
  // An agent's edit tells the owner (debounced); their own typing in the editor doesn't.
  const notify = deps.actor === "agent";
  // SQLite changes() fences the alert, the summary update and the version to the CAS on the paper.
  const [result] = await db.batch([
    db.update(papers).set(saved).where(and(eq(papers.summaryId, paper.summaryId), eq(papers.revision, paper.revision))),
    ...(notify ? [queuePaperChangesStatement(db, summary.id, revision, updatedAt)] : []),
    db.update(summaries).set(changes).where(and(eq(summaries.id, summary.id), sql`changes() > 0`)),
    ...paperAssetStatements(db, summary.id, document, updatedAt, true),
    ...(options.version ? versionStatements(db, summary, paperContent(document), { at: updatedAt, actor: deps.actor, restoredFrom: deps.restoredFrom, fenced: true }) : []),
  ]);
  if (result.rowsAffected === 0) {
    const current = await findPaperRow(db, paper.summaryId);
    if (!current) throw paperNotFound();
    throw revisionConflict(current.revision);
  }
  if (notify) runAfter(() => startPaperNotification(summary.id).catch(() => console.warn("[papers] notification not started")));
  const updated = { ...summary, ...changes };
  runAfter(() => indexSummary(db, ai, updated));
  await checkReferences(db, summary.id, document, { ai, now }, deps);
  return paperJson(db, updated, { ...paper, ...saved }, summary.ownerId);
}

/**
 * `PUT /api/v1/papers/:id`: the editor's autosave of the working copy it edited at `revision`.
 * It is not a version: the edits since the last one become one when the editor closes
 * (`commitPaper`), or before an agent edit or a restore lands on top of them.
 */
export async function autosavePaper(db: Database, ownerId: string, id: string, input: PutPaperInput, deps: PaperSaveDeps = {}): Promise<PaperJson> {
  const { summary, paper } = await getOwnedPaper(db, id, ownerId);
  if (paper.revision !== input.revision) throw revisionConflict(paper.revision);
  const document = validPaper({ title: input.title, files: input.files, mainFile: input.mainFile, compiler: input.compiler }, "The save");
  if (samePaper(documentOf(summary, paper), document)) return paperJson(db, summary, paper, ownerId);
  return savePaper(db, deps, summary, paper, document, { version: false });
}

/**
 * Saves the working copy's manual edits as a version (`actor: "owner"`), if there are any that
 * differ from the latest version. Returns the version added, or null when there was nothing to save.
 */
async function commitPending(db: Database, summary: SummaryRow, paper: PaperRow, now: Date): Promise<number | null> {
  if (paper.revision <= paper.versionedRevision) return null;
  const document = documentOf(summary, paper);
  const [latest] = await db.select({ content: documentVersions.content }).from(documentVersions)
    .where(eq(documentVersions.summaryId, summary.id)).orderBy(desc(documentVersions.version)).limit(1);
  const unchanged = latest ? samePaper(latest.content as unknown as VersionContentByKind["paper"], document) : false;
  // Fenced to the revision read: an autosave landing in between is left for the next commit.
  const [result] = await db.batch([
    db.update(papers).set({ versionedRevision: paper.revision })
      .where(and(eq(papers.summaryId, paper.summaryId), eq(papers.revision, paper.revision))),
    ...(unchanged ? [] : versionStatements(db, summary, paperContent(document), { at: now, actor: "owner", fenced: true })),
  ]);
  if (result.rowsAffected === 0 || unchanged) return null;
  return latestVersionNumber(db, summary.id);
}

/**
 * `POST /api/v1/papers/:id/versions`: the editor closed (or the user asked to save a version):
 * the manual edits since the last version become one. `version` is null when nothing changed.
 */
export async function commitPaper(db: Database, ownerId: string, id: string, deps: Pick<ServiceDeps, "now"> = {}): Promise<{ paper: PaperJson; version: number | null }> {
  const { now } = await resolveDeps(deps);
  const { summary, paper } = await getOwnedPaper(db, id, ownerId);
  const version = await commitPending(db, summary, paper, now());
  const fresh = await getOwnedPaper(db, id, ownerId);
  return { paper: await paperJson(db, fresh.summary, fresh.paper, ownerId), version };
}

/**
 * Saves `next(current)` as its own version on the latest working copy, retrying when another save
 * lands in between. Manual edits not saved as a version yet are first saved as the owner's version,
 * so an agent edit or a restore never folds them into its own.
 */
async function saveAsVersion(
  db: Database,
  ownerId: string,
  id: string,
  next: (current: PaperDocument) => PaperDocument,
  deps: PaperSaveDeps & { revision?: number | null },
): Promise<PaperJson> {
  const { now } = await resolveDeps(deps);
  for (let attempt = 0; ; attempt += 1) {
    let { summary, paper } = await getOwnedPaper(db, id, ownerId);
    if (deps.revision != null && deps.revision !== paper.revision) throw revisionConflict(paper.revision);
    if (paper.revision > paper.versionedRevision) {
      await commitPending(db, summary, paper, now());
      ({ summary, paper } = await getOwnedPaper(db, id, ownerId));
    }
    const current = documentOf(summary, paper);
    const document = next(current);
    if (samePaper(current, document)) return paperJson(db, summary, paper, ownerId);
    try {
      return await savePaper(db, deps, summary, paper, document, { version: true });
    } catch (error) {
      if (deps.revision == null && attempt < 2 && error instanceof ApiError && error.code === "PAPER_REVISION_CONFLICT") continue;
      throw error;
    }
  }
}

/**
 * MCP `update_paper`: operations applied in order as one edit, saved as their own version
 * (`actor: "agent"`). With `revision`, a paper that changed since is a 409.
 */
export async function applyPaperEdits(
  db: Database,
  ownerId: string,
  id: string,
  input: { operations: PaperOperation[]; revision?: number | null },
  deps: PaperSaveDeps = {},
): Promise<PaperJson> {
  return saveAsVersion(db, ownerId, id, (current) => applyPaperOperations(current, input.operations), { actor: "agent", referenceChecks: "now", ...deps, revision: input.revision });
}

/** `versions.ts`: brings a version's source back as a new version (`actor: "restore"`). */
export async function restorePaper(db: Database, ownerId: string, id: string, document: PaperDocument, deps: PaperSaveDeps = {}): Promise<PaperJson> {
  const restored = validPaper(document, "Restoring this version");
  return saveAsVersion(db, ownerId, id, () => restored, { referenceQuietMs: 0, ...deps });
}

/* ------------------------------------------------------------------------------------------------
 * PDF
 * ---------------------------------------------------------------------------------------------- */

function pdfKeyFor(summaryId: string, hash: string): string {
  return `papers/${summaryId}/${hash}.pdf`;
}

export async function compilePaperDocument(project: PaperDocument, strict: boolean, paperId: string, store: ObjectStore): Promise<LatexResult> {
  const compiler = await getLatexCompiler();
  const assetData: Record<string, Uint8Array> = {};
  await Promise.all(project.files.map(async (file) => {
    if (file.asset) assetData[file.path] = (await paperAssetBytes(store, paperId, file)).bytes;
  }));
  try {
    return await compiler.compile({ files: project.files, mainFile: project.mainFile, compiler: project.compiler, assetData }, { strict });
  } catch (error) {
    if (error instanceof LatexCompilerError) {
      console.error("[papers] compile service failed", error.message);
      throw new ApiError(503, "LATEX_UNAVAILABLE", "The LaTeX service is unavailable right now. Please try again in a moment.");
    }
    throw error;
  }
}

/** A filename for downloads, from the title. */
export function paperFilename(title: string): string {
  const base = title.replace(/[\\/:*?"<>|%\u0000-\u001f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 120);
  return `${base || "paper"}.pdf`;
}

/**
 * The working copy as a PDF, compiled once per source (the last one is kept in storage, so an
 * unchanged paper downloads at once). A compile that produces no PDF is `422 LATEX_COMPILE_FAILED`.
 * `version` compiles a saved version instead; those aren't kept.
 */
export async function paperPdf(
  db: Database,
  id: string,
  viewerId: string | null,
  options: { version?: number; viaLink?: boolean; store?: ObjectStore } = {},
): Promise<{ bytes: Uint8Array; filename: string; revision: number | null }> {
  const found = await findPaperForViewer(db, id, viewerId, options.viaLink);
  if (!found) throw paperNotFound();
  const { summary, paper } = found;
  const store = options.store ?? (await resolveDeps()).store;

  if (options.version !== undefined) {
    // Versions keep text the owner may have removed since: only the owner reads them.
    if (summary.ownerId !== viewerId) throw paperNotFound();
    const [row] = await db.select().from(documentVersions)
      .where(and(eq(documentVersions.summaryId, id), eq(documentVersions.version, options.version))).limit(1);
    if (!row) throw new ApiError(404, "VERSION_NOT_FOUND", `Version ${options.version} does not exist (only the latest versions are kept)`);
    const document = renderLatex(row.content as unknown as VersionContentByKind["paper"], paper.renderingOptions);
    const result = await compilePaperDocument(document, false, id, store);
    if (!result.ok) throw compileFailed(result);
    return { bytes: result.pdf, filename: paperFilename(document.title), revision: null };
  }

  const document = renderLatex(documentOf(summary, paper), paper.renderingOptions);
  const hash = paperHash(document);
  if (paper.pdfHash === hash && paper.pdfKey) {
    const cached = await store.get(paper.pdfKey).catch(() => null);
    if (cached) return { bytes: cached.bytes, filename: paperFilename(summary.title), revision: paper.revision };
  }
  const result = await compilePaperDocument(document, false, id, store);
  if (!result.ok) throw compileFailed(result);
  await cachePdf(db, store, paper, hash, result.pdf);
  return { bytes: result.pdf, filename: paperFilename(summary.title), revision: paper.revision };
}

/** Keeps the working copy's latest PDF, replacing the one before (unless the source moved on meanwhile). */
async function cachePdf(db: Database, store: ObjectStore, paper: PaperRow, hash: string, pdf: Uint8Array): Promise<void> {
  const key = pdfKeyFor(paper.summaryId, hash);
  try {
    await store.put(key, { bytes: pdf, contentType: "application/pdf", cacheControl: "private, max-age=0" });
    const result = await db.update(papers).set({ pdfHash: hash, pdfKey: key })
      .where(and(eq(papers.summaryId, paper.summaryId), eq(papers.revision, paper.revision), eq(papers.renderingOptions, paper.renderingOptions)));
    if (result.rowsAffected > 0 && paper.pdfKey && paper.pdfKey !== key) await store.delete(paper.pdfKey).catch(() => undefined);
  } catch (error) {
    console.warn("[papers] PDF not cached", error);
  }
}

/**
 * MCP `compile_paper`: compiles the working copy and stops at the first error, so the agent gets
 * the error with its file and line to fix. A success is kept as the paper's PDF.
 */
export async function checkPaper(db: Database, ownerId: string, id: string, deps: Pick<ServiceDeps, "store"> = {}): Promise<{ ok: true; revision: number; byteSize: number } | ({ ok: false; revision: number } & PaperCompileFailure)> {
  const { summary, paper } = await getOwnedPaper(db, id, ownerId);
  const document = renderLatex(documentOf(summary, paper), paper.renderingOptions);
  const store = deps.store ?? (await resolveDeps()).store;
  const result = await compilePaperDocument(document, true, id, store);
  if (!result.ok) return { ok: false, revision: paper.revision, errors: result.errors, log: result.log };
  await cachePdf(db, store, paper, paperHash(document), result.pdf);
  return { ok: true, revision: paper.revision, byteSize: result.pdf.byteLength };
}

/** Private image preview, gated by access to the paper; past versions remain owner-only. */
export async function getPaperAsset(db: Database, id: string, viewerId: string, path: string, version?: number, store?: ObjectStore) {
  const found = await findPaperForViewer(db, id, viewerId);
  if (!found) throw paperNotFound();
  let document = documentOf(found.summary, found.paper);
  if (version !== undefined) {
    if (found.summary.ownerId !== viewerId) throw paperNotFound();
    const [row] = await db.select().from(documentVersions).where(and(eq(documentVersions.summaryId, id), eq(documentVersions.version, version))).limit(1);
    if (!row) throw new ApiError(404, "VERSION_NOT_FOUND", "The paper version does not exist");
    document = row.content as unknown as PaperDocument;
  }
  const file = document.files.find((file) => file.path === path && file.asset);
  if (!file) throw new ApiError(404, "NOT_FOUND", "The image is not in this paper");
  return paperAssetBytes(store ?? (await resolveDeps()).store, id, file);
}
