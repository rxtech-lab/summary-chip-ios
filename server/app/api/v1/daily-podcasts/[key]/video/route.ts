import { podcastStream } from "@/lib/http/podcast-stream";
import { createPodcastVideoSchema, podcastDaySchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createPodcastVideo, podcastVideoSource } from "@/lib/services/podcast-video";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;
type Context = { params: Promise<{ key: string }> };

/** The episode's motion video composition, rendered by the app on device. No AI or points. */
export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key } = await context.params;
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    return noStoreJson({ video: await podcastVideoSource(db, principal.sub, day, key) });
  });
}

/** Writes a new composition with the video model; spends points. Returns the updated episode. */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal, requestId }) => {
    const { key } = await context.params;
    const { day } = await readJson(request, body => createPodcastVideoSchema.parse(body));
    const deps = { billingEnvironment: await billingEnvironment(request, principal) };
    if (request.headers.get("accept")?.split(",").some((type) => type.trim().split(";")[0] === "text/event-stream")) {
      return podcastStream((report) => createPodcastVideo(db, principal.sub, day, key, deps, report), requestId);
    }
    return noStoreJson({ podcast: await createPodcastVideo(db, principal.sub, day, key, deps) });
  });
}
