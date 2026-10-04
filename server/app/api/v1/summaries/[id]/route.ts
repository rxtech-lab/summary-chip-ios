import { patchSummarySchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { deleteSummary, getSummaryForViewer, patchSummary, readSummaryJson } from "@/lib/services/summaries";
import { acceptedLanguage } from "@/lib/services/translations";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** Translating the source document continues after the response (`after`). */
export const maxDuration = 300;

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    // The owner reads their chosen `displayLanguage`; anyone else their `Accept-Language`.
    const row = await getSummaryForViewer(db, id, principal.sub);
    return noStoreJson(await readSummaryJson(db, row, principal.sub, acceptedLanguage(request), {
      billingEnvironment: () => billingEnvironment(request, principal),
    }));
  });
}

export async function PATCH(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const patch = await readJson(request, (body) => patchSummarySchema.parse(body));
    return noStoreJson(await patchSummary(db, principal.sub, id, patch, { billingEnvironment: () => billingEnvironment(request, principal) }));
  });
}

export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await deleteSummary(db, principal.sub, id);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  });
}
