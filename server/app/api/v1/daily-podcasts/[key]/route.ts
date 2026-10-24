import { podcastDaySchema } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { dailyPodcastEpisode, selectDailyPodcast, removeDailyPodcast } from "@/lib/services/daily-podcast";
type Context = { params: Promise<{ key: string }> };
function handle(request: Request, context: Context, action: "get" | "select" | "delete") {
  return withApiAuth(request, async ({ principal, db }) => {
    const { key } = await context.params;
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    if (action === "delete") { await removeDailyPodcast(db, principal.sub, day, key); return noStoreJson({ deleted: true }); }
    return noStoreJson({ podcast: await (action === "select" ? selectDailyPodcast : dailyPodcastEpisode)(db, principal.sub, day, key) });
  });
}
export const GET = (request: Request, context: Context) => handle(request, context, "get");
export const PATCH = (request: Request, context: Context) => handle(request, context, "select");
export const DELETE = (request: Request, context: Context) => handle(request, context, "delete");
