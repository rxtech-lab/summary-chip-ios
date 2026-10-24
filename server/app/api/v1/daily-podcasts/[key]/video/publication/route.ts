import { podcastDaySchema, podcastVideoPublicationSchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { publishPodcastVideo, unpublishPodcastVideo } from "@/lib/services/podcast-video";

export const runtime = "nodejs";
type Context = { params: Promise<{ key: string }> };

/** Confirms an uploaded render: the episode's share links play it from now on. */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key } = await context.params;
    const input = await readJson(request, body => podcastVideoPublicationSchema.parse(body));
    return noStoreJson({ podcast: await publishPodcastVideo(db, principal.sub, input, key) });
  });
}

/** Removes the published render; share links fall back to audio. */
export async function DELETE(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key } = await context.params;
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    return noStoreJson({ podcast: await unpublishPodcastVideo(db, principal.sub, day, key) });
  });
}
