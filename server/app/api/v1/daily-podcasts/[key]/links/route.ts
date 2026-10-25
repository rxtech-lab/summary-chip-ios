import { createPodcastShareLinkSchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createPodcastShareLink, listPodcastShareLinks } from "@/lib/services/podcast-sharing";

export const runtime = "nodejs";
export const maxDuration = 180;
type Context = { params: Promise<{ key: string }> };

/** The episode's share links, oldest first (owner only). */
export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key } = await context.params;
    return noStoreJson(await listPodcastShareLinks(db, principal.sub, key));
  });
}

/** Creates a share link to the saved episode with its own lifetime. */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key } = await context.params;
    const input = await readJson(request, body => createPodcastShareLinkSchema.parse(body));
    return noStoreJson(await createPodcastShareLink(db, principal.sub, key, input), { status: 201 });
  });
}
