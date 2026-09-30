import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { getFacets } from "@/lib/services/summaries";

export const runtime = "nodejs";

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson(await getFacets(db, principal.sub)));
}
