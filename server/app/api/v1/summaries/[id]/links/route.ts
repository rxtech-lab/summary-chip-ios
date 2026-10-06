import { createShareLinkSchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createShareLink, listShareLinks } from "@/lib/services/share-links";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** The summary's extra share links, oldest first (owner only). */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await listShareLinks(db, principal.sub, id));
  });
}

/** Creates a share link with its own lifetime, open to anyone or only to invited emails. */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => createShareLinkSchema.parse(body));
    return noStoreJson(await createShareLink(db, principal.sub, id, input), { status: 201 });
  });
}
