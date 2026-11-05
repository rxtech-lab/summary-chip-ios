import { createAudiobookSchema } from "@/lib/contracts/audiobook";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createAudiobookPlan } from "@/lib/services/audiobooks";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;
/** Reads the sources and drafts the plan (spends points). Without `planMode` the plan is confirmed and its job returned. */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, body => createAudiobookSchema.parse(body));
    return noStoreJson(await createAudiobookPlan(db, principal.sub, input, { billingEnvironment: await billingEnvironment(request, principal) }));
  });
}
