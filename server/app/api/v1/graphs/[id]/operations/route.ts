import { graphOperationsRequestSchema } from "@/lib/contracts/graph";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { editGraph } from "@/lib/services/graphs";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** Adds, changes or removes nodes, edges and saved queries as one change. */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => graphOperationsRequestSchema.parse(body));
    return noStoreJson({ graph: await editGraph(db, principal.sub, id, input) });
  });
}
