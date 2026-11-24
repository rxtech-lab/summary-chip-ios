import { createTourSchema } from "@/lib/contracts/tour";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { getOrCreateTour } from "@/lib/services/trip-tour";
import { preferredLanguage } from "@/lib/services/translations";

export const runtime = "nodejs";
/** Narrating a long trip runs several model calls in parallel. */
export const maxDuration = 180;

type Context = { params: Promise<{ id: string }> };

/**
 * Returns a current trip tour or writes a new narration.
 */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => createTourSchema.parse(body ?? {}));
    const accepted = preferredLanguage(request.headers.get("accept-language"));
    const tour = await getOrCreateTour(db, id, principal.sub, accepted, input);
    return noStoreJson({ tour });
  }, { feature: "trips" });
}
