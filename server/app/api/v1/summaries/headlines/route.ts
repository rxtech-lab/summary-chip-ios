import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { runAfter } from "@/lib/http/after";
import { getHeadlines, rerankHeadlines } from "@/lib/services/headlines";

export const runtime = "nodejs";
export const maxDuration = 60;
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const result = await getHeadlines(db, principal.sub);
    if (result.pending) runAfter(() => rerankHeadlines(db, principal.sub));
    return noStoreJson(result);
  });
}
