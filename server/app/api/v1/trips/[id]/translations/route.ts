import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { getTripTranslations } from "@/lib/services/trips";

export const runtime = "nodejs";

/**
 * `{ originalLanguage, items: [{ language, upToDate }] }`: the languages the trip is already
 * translated into, so a language picker can tell which ones switch at once.
 */
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await getTripTranslations(db, id, principal.sub));
  }, { feature: "trips" });
}
