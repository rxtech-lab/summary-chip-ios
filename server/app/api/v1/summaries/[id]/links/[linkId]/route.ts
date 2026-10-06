import { patchShareLinkSchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { deleteShareLink, patchShareLink } from "@/lib/services/share-links";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string; linkId: string }> };

/** Changes a link's label, access, lifetime or invited emails (`emails` replaces the list). */
export async function PATCH(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id, linkId } = await params;
    const patch = await readJson(request, (body) => patchShareLinkSchema.parse(body));
    return noStoreJson(await patchShareLink(db, principal.sub, id, linkId, patch));
  });
}

/** Deletes the link; everyone who opened the summary through it loses access. */
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id, linkId } = await params;
    await deleteShareLink(db, principal.sub, id, linkId);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  });
}
