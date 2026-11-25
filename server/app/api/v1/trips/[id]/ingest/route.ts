import { ingestTripSchema } from "@/lib/contracts/trip";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { ingestTrip } from "@/lib/services/trips";

export const runtime = "nodejs";
/** The trip agent reads the source and edits the trip after the `202` (`after`), within this budget. */
export const maxDuration = 300;

type Context = { params: Promise<{ id: string }> };

/**
 * Queues a page or text shared into a trip. A "Trip updated" push follows.
 */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => ingestTripSchema.parse(body));
    return noStoreJson(await ingestTrip(db, principal, id, input), { status: 202 });
  }, { feature: "trips", requireSubscription: true });
}
