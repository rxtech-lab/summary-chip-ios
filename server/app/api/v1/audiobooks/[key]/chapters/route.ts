import { selectAudiobookChapterVersionSchema } from "@/lib/contracts/audiobook";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { selectAudiobookChapterVersion } from "@/lib/services/audiobooks";

export const runtime = "nodejs";
/** Chooses which recording of a chapter the book plays. Free and instant; returns the updated book. */
export async function PATCH(request: Request, context: { params: Promise<{ key: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { day, chapter, version } = await readJson(request, body => selectAudiobookChapterVersionSchema.parse(body));
    return noStoreJson({ podcast: await selectAudiobookChapterVersion(db, principal.sub, day, (await context.params).key, { chapter, version }) });
  });
}
