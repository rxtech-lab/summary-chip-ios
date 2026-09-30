import { patchSummarySchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { toSummaryJson } from "@/lib/services/serialize";
import { deleteSummary, getSummaryForViewer, patchSummary } from "@/lib/services/summaries";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(toSummaryJson(await getSummaryForViewer(db, id, principal.sub), principal.sub));
  });
}

export async function PATCH(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const patch = await readJson(request, (body) => patchSummarySchema.parse(body));
    return noStoreJson(await patchSummary(db, principal.sub, id, patch));
  });
}

export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await deleteSummary(db, principal.sub, id);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  });
}
