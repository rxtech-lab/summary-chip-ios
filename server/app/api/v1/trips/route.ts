import { createTripSchema } from "@/lib/contracts/trip";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createTrip, listTrips } from "@/lib/services/trips";

export const runtime = "nodejs";
/** Creating a trip designs and renders its cover (like an import, without the duplicate check). */
export const maxDuration = 120;

/** The caller's trips: ongoing and upcoming first, then past ones. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson(await listTrips(db, principal.sub)));
}

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createTripSchema.parse(body));
    return noStoreJson({ trip: await createTrip(db, principal, input) }, { status: 201 });
  });
}
