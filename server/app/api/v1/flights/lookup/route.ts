import { flightLookupSchema } from "@/lib/contracts/flights";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { lookupFlight } from "@/lib/services/flights";

export const runtime = "nodejs";

/** A flight on a day, from the backend's copy when fresh; `404 FLIGHT_NOT_FOUND` when there is none. */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ db }) => {
    const input = await readJson(request, (body) => flightLookupSchema.parse(body));
    return noStoreJson({ flight: await lookupFlight(db, input) });
  });
}
