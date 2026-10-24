import { patchPodcastShareLinkSchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { deletePodcastShareLink, patchPodcastShareLink } from "@/lib/services/podcast-sharing";

export const runtime = "nodejs";
type Context = { params: Promise<{ key: string; linkId: string }> };

/** Changes a link's label or lifetime (a new `ttlDays` restarts it). */
export async function PATCH(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key, linkId } = await context.params;
    const patch = await readJson(request, body => patchPodcastShareLinkSchema.parse(body));
    return noStoreJson(await patchPodcastShareLink(db, principal.sub, key, linkId, patch));
  });
}

/** Deletes the link; it stops opening at once. */
export async function DELETE(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key, linkId } = await context.params;
    await deletePodcastShareLink(db, principal.sub, key, linkId);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  });
}
