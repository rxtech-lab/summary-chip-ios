import { refinePodcastPlanSchema } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { refinePodcastPlanChat } from "@/lib/services/podcast-plans";
import { billingEnvironment } from "@/lib/subscription/environment";
export const runtime = "nodejs";
export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };
/** Revises the plan from one chat message (spends points). */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { revision, message } = await readJson(request, body => refinePodcastPlanSchema.parse(body));
    return noStoreJson({ plan: await refinePodcastPlanChat(db, principal.sub, (await context.params).id, revision, message,
      { billingEnvironment: await billingEnvironment(request, principal) }) });
  });
}
