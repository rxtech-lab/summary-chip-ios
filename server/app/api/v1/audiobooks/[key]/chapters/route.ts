import { selectAudiobookChapterVersionSchema } from "@/lib/contracts/audiobook";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { selectAudiobookChapterVersion } from "@/lib/services/audiobooks";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;
/** Chooses which recording of a chapter the book plays, rebuilding the book's recording. Free; returns the updated book. */
export async function PATCH(request: Request, context: { params: Promise<{ key: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { day, chapter, version, language } = await readJson(request, body => selectAudiobookChapterVersionSchema.parse(body));
    return noStoreJson({ podcast: await selectAudiobookChapterVersion(db, principal.sub, day, (await context.params).key, { chapter, version, language }, { billingEnvironment: await billingEnvironment(request, principal) }) });
  });
}
