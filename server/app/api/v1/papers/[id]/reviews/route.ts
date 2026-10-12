import { z } from "zod";
import { createPaperReviewSchema, PAPER_REVIEW_STATUSES } from "@/lib/contracts/paper-review";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createPaperReview, listPaperReviews } from "@/lib/services/paper-reviews";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };
const querySchema = z.object({ status: z.enum([...PAPER_REVIEW_STATUSES, "unresolved"]).optional() });

/** The owner's review comments on the paper, oldest first (`?status=` narrows them). */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const query = querySchema.parse(Object.fromEntries(new URL(request.url).searchParams));
    return noStoreJson({ reviews: await listPaperReviews(db, principal.sub, id, query.status) });
  }, { feature: "papers" });
}

/** A new comment on a selected passage; the working copy's pending edits become a version first. */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => createPaperReviewSchema.parse(body));
    return noStoreJson({ review: await createPaperReview(db, principal.sub, id, input) }, { status: 201 });
  }, { feature: "papers" });
}
