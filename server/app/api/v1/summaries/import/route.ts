import { importSummarySchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { importSummary } from "@/lib/services/summaries";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** No summarising, but an agent checks for duplicates and the cover is designed (or illustrated) by a model. */
export const maxDuration = 180;

/** Saves a summary written elsewhere — summary, tags and raw text in one call. OAuth bearer token required. */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => importSummarySchema.parse(body));
    return noStoreJson(await importSummary(db, principal, input, { billingEnvironment: await billingEnvironment(request, principal) }), { status: 201 });
  });
}
