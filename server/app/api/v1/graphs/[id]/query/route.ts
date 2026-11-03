import { runGraphQuerySchema } from "@/lib/contracts/graph";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { queryGraph } from "@/lib/services/graphs";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** Runs a read-only query and names the nodes and edges it matched. Saves nothing. */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const { query } = await readJson(request, (body) => runGraphQuerySchema.parse(body));
    return noStoreJson({ result: await queryGraph(db, id, principal.sub, query) });
  });
}
