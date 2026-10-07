import { putTripSchema } from "@/lib/contracts/trip";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { deleteSummary } from "@/lib/services/summaries";
import { getTrip, readTripJson, replaceTrip } from "@/lib/services/trips";
import { acceptedLanguage } from "@/lib/services/translations";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** A trip read in another language is translated before the response. */
export const maxDuration = 120;

type Context = { params: Promise<{ id: string }> };

/**
 * The trip document (owner, or anyone signed in while its public link is live): the owner reads
 * their chosen `displayLanguage`, anyone else their `Accept-Language`.
 */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson({
      trip: await readTripJson(db, id, principal.sub, acceptedLanguage(request), {
        billingEnvironment: () => billingEnvironment(request, principal),
      }),
    });
  }, { feature: "trips" });
}

/** Saves the whole document edited at `revision`; `409 TRIP_REVISION_CONFLICT` when it changed since. */
export async function PUT(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const { input, sent } = await readJson(request, (body) => {
      const document = (body as { document?: { views?: unknown; plans?: unknown } } | null)?.document;
      return {
        input: putTripSchema.parse(body),
        sent: { views: Array.isArray(document?.views), plans: Array.isArray(document?.plans) },
      };
    });
    return noStoreJson({ trip: await replaceTrip(db, principal.sub, id, input, {}, sent) });
  }, { feature: "trips" });
}

/** Same as deleting the summary: the trip row goes with it. */
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await getTrip(db, id, principal.sub);
    await deleteSummary(db, principal.sub, id);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  }, { feature: "trips" });
}
