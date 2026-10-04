import { createSummarySchema, listQuerySchema, queryObject } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createSummary, listSummaries } from "@/lib/services/summaries";
import { acceptedLanguage } from "@/lib/services/translations";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** Extraction + two model calls + OG rendering; the contract allows up to ~90 s. */
/** The summary is returned within ~90 s; the document agent keeps the function alive after the response (`after`). */
export const maxDuration = 300;

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createSummarySchema.parse(body));
    return noStoreJson(await createSummary(db, principal, input, { billingEnvironment: await billingEnvironment(request, principal) }), { status: 201 });
  });
}

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const query = listQuerySchema.parse(queryObject(request));
    // Others' summaries come back in the caller's language; missing translations are written after the response.
    return noStoreJson(await listSummaries(db, principal.sub, query, { accepted: acceptedLanguage(request) }));
  });
}
