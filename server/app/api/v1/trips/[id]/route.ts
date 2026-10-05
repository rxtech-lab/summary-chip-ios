import { putTripSchema } from "@/lib/contracts/trip";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { deleteSummary } from "@/lib/services/summaries";
import { getTrip, replaceTrip } from "@/lib/services/trips";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** The trip document (owner, or anyone signed in while its public link is live). */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson({ trip: await getTrip(db, id, principal.sub) });
  });
}

/** Saves the whole document edited at `revision`; `409 TRIP_REVISION_CONFLICT` when it changed since. */
export async function PUT(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const { input, hasViews } = await readJson(request, (body) => ({
      input: putTripSchema.parse(body),
      hasViews: Array.isArray((body as { document?: { views?: unknown } } | null)?.document?.views),
    }));
    return noStoreJson({ trip: await replaceTrip(db, principal.sub, id, input, {}, hasViews) });
  });
}

/** Same as deleting the summary: the trip row goes with it. */
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await getTrip(db, id, principal.sub);
    await deleteSummary(db, principal.sub, id);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  });
}
