import { podcastStream } from "@/lib/http/podcast-stream";
import { createPodcastTranslationSchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { podcastInLanguage } from "@/lib/services/daily-podcast";
import { translateDailyPodcast } from "@/lib/services/podcast-translation";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;

/** Speaks the episode in another language (spends points) and returns it in that language. */
export async function POST(request: Request, context: { params: Promise<{ key: string }> }) {
  return withApiAuth(request, async ({ principal, db, requestId }) => {
    const { key } = await context.params;
    const { day, ...input } = await readJson(request, (body) => createPodcastTranslationSchema.parse(body));
    const deps = { billingEnvironment: await billingEnvironment(request, principal) };
    const translate = async (report?: Parameters<typeof translateDailyPodcast>[6]) =>
      podcastInLanguage(await translateDailyPodcast(db, principal.sub, day, key, input, deps, report), input.language);
    if (request.headers.get("accept")?.split(",").some((type) => type.trim().split(";")[0] === "text/event-stream")) {
      return podcastStream((report) => translate(report), requestId);
    }
    return noStoreJson({ podcast: await translate() });
  });
}
