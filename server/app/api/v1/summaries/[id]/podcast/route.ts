import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { libraryPodcast, podcastInLanguage } from "@/lib/services/daily-podcast";
import { podcastLanguageQuery } from "@/lib/contracts/daily-podcast";
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await context.params;
    const podcast = await libraryPodcast(db, principal.sub, id);
    const language = podcastLanguageQuery(new URL(request.url).searchParams);
    return noStoreJson({ podcast: podcastInLanguage(podcast, language && podcast.translations?.[language] ? language : undefined) });
  });
}
