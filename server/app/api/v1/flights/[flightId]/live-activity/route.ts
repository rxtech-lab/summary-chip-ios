import { flightLiveActivityRemovalSchema, flightLiveActivitySchema } from "@/lib/contracts/flights";
import { withApiAuth } from "@/lib/http/handler";
import { readJson } from "@/lib/http/errors";
import { registerFlightLiveActivity, removeFlightLiveActivity } from "@/lib/services/flights";

export const runtime = "nodejs";

type Context = { params: Promise<{ flightId: string }> };

/** A running Live Activity's update token; the backend pushes the flight's changes to it. */
export async function PUT(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { flightId } = await params;
    const input = await readJson(request, (body) => flightLiveActivitySchema.parse(body));
    await registerFlightLiveActivity(db, principal.sub, flightId, input);
    return new Response(null, { status: 204 });
  });
}

/** The activity ended on the device. */
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { flightId } = await params;
    const input = await readJson(request, (body) => flightLiveActivityRemovalSchema.parse(body));
    await removeFlightLiveActivity(db, principal.sub, flightId, input.installationId);
    return new Response(null, { status: 204 });
  });
}
