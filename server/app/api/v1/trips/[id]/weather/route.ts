import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { tripWeatherForViewer } from "@/lib/services/weather";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** The trip's weather forecasts, as last refreshed by the tracker (never fetched live). */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await tripWeatherForViewer(db, id, principal.sub));
  }, { feature: "trips" });
}
