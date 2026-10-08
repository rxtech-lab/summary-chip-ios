import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { checkPaper } from "@/lib/services/papers";

export const runtime = "nodejs";
export const maxDuration = 120;

/**
 * `{ ok, revision, … }`: compiles the working copy, stopping at the first error. The preview
 * (`GET …/pdf`) recovers from errors and still draws a PDF; this lists them:
 * `{ ok: false, errors: [{ file, line, message }], log }`.
 */
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    return noStoreJson(await checkPaper(db, principal.sub, id));
  }, { feature: "papers" });
}
