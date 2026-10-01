import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { getSourceMarkdown } from "@/lib/services/summaries";

export const runtime = "nodejs";

/** `{ markdown }`: the summary's source rewritten as Markdown; 404 `SOURCE_NOT_KEPT` when it was not kept. */
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await getSourceMarkdown(db, id, principal.sub));
  });
}
