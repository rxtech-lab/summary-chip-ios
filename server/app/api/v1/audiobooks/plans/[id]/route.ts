import { confirmAudiobookPlanSchema, reviseAudiobookPlanSchema } from "@/lib/contracts/audiobook";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { confirmAudiobookPlan, deleteAudiobookPlan, readAudiobookPlan, reviseAudiobookPlan } from "@/lib/services/audiobooks";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 60;
type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ plan: await readAudiobookPlan(db, principal.sub, (await context.params).id) }));
}
/** Saves edits: speakers and voices, chapters, music, scenes, the video theme. */
export async function PATCH(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { revision, plan } = await readJson(request, body => reviseAudiobookPlanSchema.parse(body));
    return noStoreJson({ plan: await reviseAudiobookPlan(db, principal.sub, (await context.params).id, revision, plan) });
  });
}
/** Confirms the reviewed revision and starts making the audiobook; progress is read from the returned job. */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { revision, chapters } = await readJson(request, body => confirmAudiobookPlanSchema.parse(body));
    return noStoreJson({ job: await confirmAudiobookPlan(db, principal.sub, (await context.params).id, revision, { billingEnvironment: await billingEnvironment(request, principal) }, chapters) });
  });
}
export async function DELETE(request: Request, context: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    await deleteAudiobookPlan(db, principal.sub, (await context.params).id);
    return new Response(null, { status: 204 });
  });
}
