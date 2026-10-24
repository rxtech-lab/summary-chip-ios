import { createDailyPodcastSchema, podcastDaySchema } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createDailyPodcast, savedDailyPodcast } from "@/lib/services/daily-podcast";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    return noStoreJson({ podcast: await savedDailyPodcast(db, principal.sub, day) });
  });
}
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createDailyPodcastSchema.parse(body));
    return noStoreJson({ podcast: await createDailyPodcast(db, principal.sub, input, { billingEnvironment: await billingEnvironment(request, principal) }) });
  });
}
