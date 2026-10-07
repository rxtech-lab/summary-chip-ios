import { planSelectionSchema } from "@/lib/contracts/trip";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { selectPlanOption } from "@/lib/services/trips";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/**
 * The caller picks an option of one of the trip's plans (`{ planId, optionId }`; `optionId: null`
 * goes back to the default). Saved for them only; the trip document and its revision don't change.
 */
export async function PUT(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => planSelectionSchema.parse(body));
    return noStoreJson(await selectPlanOption(db, principal.sub, id, input));
  }, { feature: "trips" });
}
