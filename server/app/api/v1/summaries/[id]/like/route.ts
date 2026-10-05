import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { setSummaryLiked } from "@/lib/services/summaries";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** Stars the summary for the caller (idempotent); returns `{ likedAt }`. */
export async function PUT(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await setSummaryLiked(db, principal.sub, id, true));
  });
}

/** Removes the caller's star (idempotent); returns `{ likedAt: null }`. */
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await setSummaryLiked(db, principal.sub, id, false));
  });
}
