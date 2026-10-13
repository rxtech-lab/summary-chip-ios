import { z } from "zod";
import { paperPathSchema } from "./paper";

/**
 * Review comments on a paper (`docs/papers.md` → Reviews): the owner selects a passage in the
 * app's reader and leaves a comment; an agent reads them with `get_paper_reviews`, edits the
 * paper, and marks them addressed with `finish_paper_review`; the owner then reads the change
 * as a diff and resolves the review. `Packages/SummaryKit/Sources/SummaryKit/Models/PaperReview.swift`
 * mirrors it.
 */

export const MAX_REVIEW_QUOTE_CHARS = 2000;
export const MAX_REVIEW_COMMENT_CHARS = 4000;
export const MAX_REVIEW_NOTE_CHARS = 4000;
export const MAX_REVIEWS_PER_PAPER = 200;

export const PAPER_REVIEW_STATUSES = ["open", "addressed", "resolved"] as const;
export type PaperReviewStatus = (typeof PAPER_REVIEW_STATUSES)[number];

export const createPaperReviewSchema = z.object({
  quote: z.string().trim().min(1).max(MAX_REVIEW_QUOTE_CHARS),
  comment: z.string().trim().min(1).max(MAX_REVIEW_COMMENT_CHARS),
  file: paperPathSchema.optional(),
});
export type CreatePaperReviewInput = z.infer<typeof createPaperReviewSchema>;

/** The owner edits the comment, resolves an addressed review, or reopens one. */
export const patchPaperReviewSchema = z.object({
  comment: z.string().trim().min(1).max(MAX_REVIEW_COMMENT_CHARS).optional(),
  status: z.enum(["open", "resolved"]).optional(),
}).refine((patch) => patch.comment !== undefined || patch.status !== undefined, { message: "Nothing to change" });
export type PatchPaperReviewInput = z.infer<typeof patchPaperReviewSchema>;

/** MCP `finish_paper_review`: the agent has edited the paper for these reviews. */
export const finishPaperReviewsSchema = z.object({
  reviewIds: z.array(z.string().trim().min(1).max(100)).min(1).max(MAX_REVIEWS_PER_PAPER),
  note: z.string().trim().max(MAX_REVIEW_NOTE_CHARS).optional(),
});
export type FinishPaperReviewsInput = z.infer<typeof finishPaperReviewsSchema>;
