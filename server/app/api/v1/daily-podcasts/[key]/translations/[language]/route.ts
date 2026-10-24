import { podcastDaySchema, podcastLanguageSchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { podcastInLanguage } from "@/lib/services/daily-podcast";
import { removePodcastTranslation } from "@/lib/services/podcast-translation";

/** Removes one translation; returns the episode in its original language. No AI or points. */
export async function DELETE(request: Request, context: { params: Promise<{ key: string; language: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { key, language } = await context.params;
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    return noStoreJson({ podcast: podcastInLanguage(await removePodcastTranslation(db, principal.sub, day, key, podcastLanguageSchema.parse(language))) });
  });
}
