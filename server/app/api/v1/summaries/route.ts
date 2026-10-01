import { createSummarySchema, listQuerySchema, queryObject } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createSummary, listSummaries } from "@/lib/services/summaries";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** Extraction + two model calls + OG rendering; the contract allows up to ~90 s. */
export const maxDuration = 120;

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createSummarySchema.parse(body));
    return noStoreJson(await createSummary(db, principal, input, { billingEnvironment: await billingEnvironment(request, principal) }), { status: 201 });
  });
}

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const query = listQuerySchema.parse(queryObject(request));
    return noStoreJson(await listSummaries(db, principal.sub, query));
  });
}
