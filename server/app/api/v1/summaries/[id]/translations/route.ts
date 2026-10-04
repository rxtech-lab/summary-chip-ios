import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { getTranslations } from "@/lib/services/summaries";

export const runtime = "nodejs";

/**
 * `{ originalLanguage, items: [{ language, sourceTranslated, sourcePending }] }`: the languages the
 * summary is already translated into, so a language picker can tell which ones switch at once.
 */
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await getTranslations(db, id, principal.sub));
  });
}
