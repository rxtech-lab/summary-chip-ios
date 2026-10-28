import { createDailyPodcastSchema } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createPodcastPlan, listPodcastPlans } from "@/lib/services/podcast-plans";
import { billingEnvironment } from "@/lib/subscription/environment";
export const runtime = "nodejs";
export const maxDuration = 300;
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, body => createDailyPodcastSchema.parse(body));
    return noStoreJson({ plan: await createPodcastPlan(db, principal.sub, input, { billingEnvironment: await billingEnvironment(request, principal) }) });
  });
}
/** The owner's unconfirmed plans, most recently changed first. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ plans: await listPodcastPlans(db, principal.sub) }));
}
