import { drawPodcastPlanFramesSchema } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { drawPodcastPlanFrames } from "@/lib/services/podcast-plans";
import { billingEnvironment } from "@/lib/subscription/environment";
export const runtime = "nodejs";
export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };
/** Draws the storyboard frames the plan's current revision is missing (spends points). */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { revision } = await readJson(request, body => drawPodcastPlanFramesSchema.parse(body));
    return noStoreJson({ plan: await drawPodcastPlanFrames(db, principal.sub, (await context.params).id, revision,
      { billingEnvironment: await billingEnvironment(request, principal) }) });
  });
}
