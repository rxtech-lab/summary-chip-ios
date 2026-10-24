import { podcastStream } from "@/lib/http/podcast-stream";
import { createDailyPodcastSchema, podcastDaySchema, podcastLanguageQuery } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createDailyPodcast, podcastInLanguage, savedDailyPodcast } from "@/lib/services/daily-podcast";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    const podcast = await savedDailyPodcast(db, principal.sub, day);
    const language = podcastLanguageQuery(query);
    // A language the episode hasn't been translated into falls back to the original.
    return noStoreJson({ podcast: podcast && podcastInLanguage(podcast, language && podcast.translations?.[language] ? language : undefined) });
  });
}
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db, requestId }) => {
    const input = await readJson(request, (body) => createDailyPodcastSchema.parse(body));
    const deps = { billingEnvironment: await billingEnvironment(request, principal) };
    if (request.headers.get("accept")?.split(",").some((type) => type.trim().split(";")[0] === "text/event-stream")) {
      return podcastStream(async (report) => podcastInLanguage(await createDailyPodcast(db, principal.sub, input, deps, report)), requestId);
    }
    return noStoreJson({ podcast: podcastInLanguage(await createDailyPodcast(db, principal.sub, input, deps)) });
  });
}
