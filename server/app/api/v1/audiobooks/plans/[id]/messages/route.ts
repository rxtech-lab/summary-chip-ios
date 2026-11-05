import { refineAudiobookPlanSchema } from "@/lib/contracts/audiobook";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { refineAudiobookPlanChat } from "@/lib/services/audiobooks";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;
/** Revises the plan from one chat request (spends points). */
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { revision, message } = await readJson(request, body => refineAudiobookPlanSchema.parse(body));
    return noStoreJson({ plan: await refineAudiobookPlanChat(db, principal.sub, (await context.params).id, revision, message, { billingEnvironment: await billingEnvironment(request, principal) }) });
  });
}
