import { liveActivityStartTokenSchema } from "@/lib/contracts/flights";
import { withApiAuth } from "@/lib/http/handler";
import { readJson } from "@/lib/http/errors";
import { setLiveActivityStartToken } from "@/lib/services/flights";

export const runtime = "nodejs";

/** The installation's ActivityKit push-to-start token (null clears it). */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => liveActivityStartTokenSchema.parse(body));
    await setLiveActivityStartToken(db, principal.sub, input.installationId, input.pushToStartToken);
    return new Response(null, { status: 204 });
  });
}
