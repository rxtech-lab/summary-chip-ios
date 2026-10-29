import { confirmPodcastPlanSchema, revisePodcastPlanSchema } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { podcastStream } from "@/lib/http/podcast-stream";
import { confirmPodcastPlan, deletePodcastPlan, readPodcastPlan, revisePodcastPlan } from "@/lib/services/podcast-plans";
import { podcastInLanguage } from "@/lib/services/daily-podcast";
import { billingEnvironment } from "@/lib/subscription/environment";
export const runtime = "nodejs";
export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };
export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ plan: await readPodcastPlan(db, principal.sub, (await context.params).id) }));
}
export async function PATCH(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, body => revisePodcastPlanSchema.parse(body));
    return noStoreJson({ plan: await revisePodcastPlan(db, principal.sub, (await context.params).id, input.revision, input.script) });
  });
}
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db, requestId }) => {
    const { revision } = await readJson(request, body => confirmPodcastPlanSchema.parse(body));
    const id = (await context.params).id;
    const deps = { billingEnvironment: await billingEnvironment(request, principal) };
    if (request.headers.get("accept")?.includes("text/event-stream")) {
      return podcastStream(async report => podcastInLanguage(await confirmPodcastPlan(db, principal.sub, id, revision, deps, report)), requestId);
    }
    return noStoreJson({ podcast: podcastInLanguage(await confirmPodcastPlan(db, principal.sub, id, revision, deps)) });
  });
}
/** Discards an unconfirmed plan and its storyboard frames. */
export async function DELETE(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    await deletePodcastPlan(db, principal.sub, (await context.params).id);
    return new Response(null, { status: 204 });
  });
}
