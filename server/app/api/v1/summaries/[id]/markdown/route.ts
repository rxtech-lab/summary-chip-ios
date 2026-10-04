import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { getSourceMarkdown } from "@/lib/services/summaries";
import { acceptedLanguage } from "@/lib/services/translations";

export const runtime = "nodejs";
/** Translating the source document continues after the response (`after`). */
export const maxDuration = 300;

/**
 * `{ markdown, language, translationPending }`: the summary's source rewritten as Markdown, in the
 * language the caller reads the summary in once translated; 404 `SOURCE_NOT_KEPT` when it was not kept.
 */
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await getSourceMarkdown(db, id, principal.sub, acceptedLanguage(request)));
  });
}
