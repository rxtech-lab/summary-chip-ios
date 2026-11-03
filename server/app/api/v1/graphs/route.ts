import { createGraphSchema } from "@/lib/contracts/graph";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createGraph, listGraphs } from "@/lib/services/graphs";

export const runtime = "nodejs";
/** Creating a graph designs and renders its cover. */
export const maxDuration = 120;

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson(await listGraphs(db, principal.sub)));
}

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createGraphSchema.parse(body));
    return noStoreJson({ graph: await createGraph(db, principal, input) }, { status: 201 });
  });
}
