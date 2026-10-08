import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { commitPaper } from "@/lib/services/papers";

export const runtime = "nodejs";

/**
 * `{ paper, version }`: saves the manual edits since the last version as a new one (the editor
 * calls it when the user leaves the paper). `version` is null when nothing changed. Versions are
 * listed, read and restored under `/api/v1/summaries/:id/versions`.
 */
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await commitPaper(db, principal.sub, id));
  }, { feature: "papers" });
}
