import { patchPaperReviewSchema } from "@/lib/contracts/paper-review";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { deletePaperReview, updatePaperReview } from "@/lib/services/paper-reviews";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string; reviewId: string }> };

/** Edits the comment, resolves an addressed review (`status: "resolved"`) or reopens it (`"open"`). */
export async function PATCH(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id, reviewId } = await params;
    const patch = await readJson(request, (body) => patchPaperReviewSchema.parse(body));
    return noStoreJson({ review: await updatePaperReview(db, principal.sub, id, reviewId, patch) });
  }, { feature: "papers" });
}

export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id, reviewId } = await params;
    await deletePaperReview(db, principal.sub, id, reviewId);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  }, { feature: "papers" });
}
