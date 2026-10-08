import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { listVersions } from "@/lib/services/versions";

export const runtime = "nodejs";

/**
 * `{ items: [{ version, kind, actor, restoredFrom, createdAt, title, isCurrent }], nextCursor }`:
 * the owner's saved versions of a summary or trip, newest first. `?cursor=` pages, `?limit=` (≤ 100).
 */
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const search = new URL(request.url).searchParams;
    const limit = search.get("limit");
    return noStoreJson(await listVersions(db, principal.sub, id, {
      cursor: search.get("cursor") ?? undefined,
      limit: limit === null ? undefined : Number(limit) || undefined,
    }));
  });
}
