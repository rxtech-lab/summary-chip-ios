import { ingestTripSchema } from "@/lib/contracts/trip";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { ingestTrip } from "@/lib/services/trips";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** The trip agent reads the source and edits the trip after the `202` (`after`), within this budget. */
export const maxDuration = 300;

type Context = { params: Promise<{ id: string }> };

/**
 * A page or text shared into a trip (the share extension's "Add to trip"). Points are held first
 * (`402 TRIP_POINTS_EXHAUSTED`), then `202 {status:"queued"}`; a "Trip updated" push follows.
 */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => ingestTripSchema.parse(body));
    return noStoreJson(await ingestTrip(db, principal, id, input, { billingEnvironment: await billingEnvironment(request, principal) }), { status: 202 });
  });
}
