import { and, asc, count, desc, eq, inArray } from "drizzle-orm";
import type { CreatePaperReviewInput, FinishPaperReviewsInput, PatchPaperReviewInput } from "@/lib/contracts/paper-review";
import { MAX_REVIEWS_PER_PAPER, type PaperReviewStatus } from "@/lib/contracts/paper-review";
import type { Database } from "@/lib/db/client";
import { documentVersions, paperReviews, type PaperReviewRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { commitPaper, getOwnedPaper } from "./papers";
import { resolveDeps, type ServiceDeps } from "./summaries";

/**
 * Review comments on a paper (`docs/papers.md` → Reviews). Each one quotes the passage the owner
 * selected in the reader and keeps the paper's version it was made on, so once an agent has
 * addressed it (recording the version holding its edits) the app can show the change as a diff.
 */

export interface PaperReviewJson {
  id: string;
  paperId: string;
  file: string | null;
  quote: string;
  comment: string;
  status: PaperReviewStatus;
  /** The paper's version the comment was made on. */
  version: number;
  /** The version holding the agent's edits for it; null until it is addressed. */
  addressedVersion: number | null;
  agentNote: string | null;
  createdAt: string;
  updatedAt: string;
  addressedAt: string | null;
  resolvedAt: string | null;
}

function reviewNotFound(): ApiError {
  return new ApiError(404, "PAPER_REVIEW_NOT_FOUND", "The review does not exist");
}

export function toPaperReviewJson(row: PaperReviewRow): PaperReviewJson {
  return {
    id: row.id,
    paperId: row.summaryId,
    file: row.file,
    quote: row.quote,
    comment: row.comment,
    status: row.status,
    version: row.version,
    addressedVersion: row.addressedVersion,
    agentNote: row.agentNote,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
    addressedAt: row.addressedAt?.toISOString() ?? null,
    resolvedAt: row.resolvedAt?.toISOString() ?? null,
  };
}

async function latestVersion(db: Database, summaryId: string): Promise<number> {
  const [row] = await db.select({ version: documentVersions.version }).from(documentVersions)
    .where(eq(documentVersions.summaryId, summaryId)).orderBy(desc(documentVersions.version)).limit(1);
  return row?.version ?? 0;
}

/** The owner's reviews of a paper, oldest first; `status` narrows them. */
export async function listPaperReviews(db: Database, ownerId: string, id: string, status?: PaperReviewStatus | "unresolved"): Promise<PaperReviewJson[]> {
  await getOwnedPaper(db, id, ownerId);
  const filter = status === "unresolved" ? inArray(paperReviews.status, ["open", "addressed"]) : status ? eq(paperReviews.status, status) : undefined;
  const rows = await db.select().from(paperReviews)
    .where(and(eq(paperReviews.summaryId, id), filter))
    .orderBy(asc(paperReviews.createdAt), asc(paperReviews.id));
  return rows.map(toPaperReviewJson);
}

/**
 * `POST /api/v1/papers/:id/reviews`: a comment on a passage. The working copy's unversioned edits
 * are saved as a version first, so the review names the exact source it was made on.
 */
export async function createPaperReview(db: Database, ownerId: string, id: string, input: CreatePaperReviewInput, deps: Pick<ServiceDeps, "now"> = {}): Promise<PaperReviewJson> {
  const { now } = await resolveDeps(deps);
  await getOwnedPaper(db, id, ownerId);
  const [{ total }] = await db.select({ total: count() }).from(paperReviews).where(eq(paperReviews.summaryId, id));
  if (total >= MAX_REVIEWS_PER_PAPER) throw new ApiError(422, "PAPER_REVIEW_LIMIT", `A paper holds at most ${MAX_REVIEWS_PER_PAPER} reviews; delete resolved ones`);
  if (input.file) {
    const { paper } = await getOwnedPaper(db, id, ownerId);
    if (!paper.files.some((file) => file.path === input.file)) throw new ApiError(422, "PAPER_REVIEW_FILE", `The paper has no file ${input.file}`);
  }
  await commitPaper(db, ownerId, id, { now });
  const at = now();
  const row: PaperReviewRow = {
    id: crypto.randomUUID(),
    summaryId: id,
    ownerId,
    file: input.file ?? null,
    quote: input.quote,
    comment: input.comment,
    status: "open",
    version: await latestVersion(db, id),
    addressedVersion: null,
    agentNote: null,
    createdAt: at,
    updatedAt: at,
    addressedAt: null,
    resolvedAt: null,
  };
  await db.insert(paperReviews).values(row);
  return toPaperReviewJson(row);
}

async function ownedReview(db: Database, ownerId: string, id: string, reviewId: string): Promise<PaperReviewRow> {
  await getOwnedPaper(db, id, ownerId);
  const [row] = await db.select().from(paperReviews).where(and(eq(paperReviews.summaryId, id), eq(paperReviews.id, reviewId))).limit(1);
  if (!row) throw reviewNotFound();
  return row;
}

/** `PATCH …/reviews/:reviewId`: the owner edits the comment, resolves the review or reopens it. */
export async function updatePaperReview(db: Database, ownerId: string, id: string, reviewId: string, patch: PatchPaperReviewInput, deps: Pick<ServiceDeps, "now"> = {}): Promise<PaperReviewJson> {
  const { now } = await resolveDeps(deps);
  const row = await ownedReview(db, ownerId, id, reviewId);
  const at = now();
  const changes: Partial<PaperReviewRow> = { updatedAt: at };
  if (patch.comment !== undefined) changes.comment = patch.comment;
  if (patch.status === "resolved") {
    changes.status = "resolved";
    changes.resolvedAt = at;
  } else if (patch.status === "open") {
    // Reopening asks the agent again; its earlier edits stay in the history.
    changes.status = "open";
    changes.resolvedAt = null;
    changes.addressedVersion = null;
    changes.addressedAt = null;
    changes.agentNote = null;
  }
  await db.update(paperReviews).set(changes).where(eq(paperReviews.id, row.id));
  return toPaperReviewJson({ ...row, ...changes });
}

export async function deletePaperReview(db: Database, ownerId: string, id: string, reviewId: string): Promise<void> {
  const row = await ownedReview(db, ownerId, id, reviewId);
  await db.delete(paperReviews).where(eq(paperReviews.id, row.id));
}

/**
 * MCP `finish_paper_review`: the agent edited the paper for these reviews. Each becomes
 * `addressed` at the paper's latest version (the agent's own `update_paper` version), so the owner
 * can read the change from the review's version to it. Resolved reviews are left alone.
 */
export async function finishPaperReviews(db: Database, ownerId: string, id: string, input: FinishPaperReviewsInput, deps: Pick<ServiceDeps, "now"> = {}): Promise<{ reviews: PaperReviewJson[]; version: number }> {
  const { now } = await resolveDeps(deps);
  await getOwnedPaper(db, id, ownerId);
  const ids = [...new Set(input.reviewIds)];
  const rows = await db.select().from(paperReviews).where(and(eq(paperReviews.summaryId, id), inArray(paperReviews.id, ids)));
  const missing = ids.filter((reviewId) => !rows.some((row) => row.id === reviewId));
  if (missing.length) throw new ApiError(404, "PAPER_REVIEW_NOT_FOUND", `No review ${missing.join(", ")} on this paper`);
  const version = await latestVersion(db, id);
  const at = now();
  const changes = { status: "addressed" as const, addressedVersion: version, addressedAt: at, agentNote: input.note || null, updatedAt: at };
  const addressed = rows.filter((row) => row.status !== "resolved").map((row) => row.id);
  if (addressed.length) await db.update(paperReviews).set(changes).where(inArray(paperReviews.id, addressed));
  return { version, reviews: rows.map((row) => toPaperReviewJson(addressed.includes(row.id) ? { ...row, ...changes } : row)) };
}
