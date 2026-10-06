import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { tripFlights } from "@/lib/services/flights";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** The trip's tracked flights, as last refreshed by the tracker (never fetched live). */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await tripFlights(db, id, principal.sub));
  }, { feature: "trips" });
}
