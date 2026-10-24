import { withPublicApi } from "@/lib/http/handler";
import { publicPodcast } from "@/lib/services/podcast-sharing";
import { publishedPodcastVideoUrl } from "@/lib/services/podcast-video";

export const runtime = "nodejs";

/**
 * The published render. The link and its sources are rechecked on every request, then the player is
 * sent to a short-lived storage URL (videos are too large to stream through a function).
 */
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withPublicApi(request, async ({ db }) => {
    const { link, podcast } = await publicPodcast(db, (await context.params).id, undefined, new URL(request.url).searchParams.get("language"));
    const url = await publishedPodcastVideoUrl(link.ownerId, podcast);
    return new Response(null, { status: 302, headers: { location: url, "cache-control": "private, no-store" } });
  });
}
