import { createAudiobookTranslationSchema } from "@/lib/contracts/audiobook";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { startAudiobookTranslation } from "@/lib/services/audiobooks";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 60;
/** Starts speaking the audiobook in another language (spends points when it finishes); returns the job to follow. */
export async function POST(request: Request, context: { params: Promise<{ key: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { day, ...input } = await readJson(request, body => createAudiobookTranslationSchema.parse(body));
    return noStoreJson({ job: await startAudiobookTranslation(db, principal.sub, day, (await context.params).key, input, { billingEnvironment: await billingEnvironment(request, principal) }) });
  });
}
