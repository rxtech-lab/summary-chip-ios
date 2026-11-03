import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { getGraph, getOwnedGraph } from "@/lib/services/graphs";
import { deleteSummary } from "@/lib/services/summaries";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** The graph document, for the owner or anyone who can read its summary. */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson({ graph: await getGraph(db, id, principal.sub) });
  });
}

/** Same as deleting the summary: the graph row goes with it. */
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await getOwnedGraph(db, id, principal.sub);
    await deleteSummary(db, principal.sub, id);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  });
}
