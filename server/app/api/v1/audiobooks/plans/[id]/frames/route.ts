import { confirmAudiobookPlanSchema } from "@/lib/contracts/audiobook";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { drawAudiobookPlanFrames } from "@/lib/services/audiobooks";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;
/** Draws the first scene images the plan is missing (spends points). The video reuses them. */
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { revision } = await readJson(request, body => confirmAudiobookPlanSchema.parse(body));
    return noStoreJson({ plan: await drawAudiobookPlanFrames(db, principal.sub, (await context.params).id, revision, { billingEnvironment: await billingEnvironment(request, principal) }) });
  });
}
