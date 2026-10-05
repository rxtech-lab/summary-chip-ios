import { tripOperationsRequestSchema } from "@/lib/contracts/trip";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { applyTripOperations } from "@/lib/services/trips";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** Entity-level edits, applied in order as one change; `revision` (optional) guards against concurrent edits. */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => tripOperationsRequestSchema.parse(body));
    return noStoreJson({ trip: await applyTripOperations(db, principal.sub, id, input) });
  });
}
