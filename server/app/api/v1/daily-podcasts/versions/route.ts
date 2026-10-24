import { podcastDaySchema } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { listDailyPodcasts, dailyPodcastChips, listLibraryPodcasts, podcastInLanguage } from "@/lib/services/daily-podcast";
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const query = new URL(request.url).searchParams;
    // A library podcast chip's versions; regenerating it adds versions instead of chips.
    const summaryId = query.get("summaryId");
    const versions = summaryId ? await listLibraryPodcasts(db, principal.sub, summaryId) : null;
    if (versions) return noStoreJson({ items: versions.map((item) => ({ ...item, podcast: podcastInLanguage(item.podcast) })) });
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    if (query.get("chips") === "true") return noStoreJson({ items: (await dailyPodcastChips(db, principal.sub, day)).map(({ chip }) => ({ id: chip.id, title: chip.title, source: chip.source })) });
    return noStoreJson({ items: (await listDailyPodcasts(db, principal.sub, day)).map((item) => ({ ...item, podcast: podcastInLanguage(item.podcast) })) });
  });
}
