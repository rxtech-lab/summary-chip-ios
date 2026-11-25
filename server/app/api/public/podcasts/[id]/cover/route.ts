import { withPublicApi } from "@/lib/http/handler";
import { publicPodcast } from "@/lib/services/podcast-sharing";
import { podcastCover } from "@/lib/services/podcast-publication";
import { hasFlowcyAccess } from "@/lib/subscription/flowcy";

export const runtime = "nodejs";
export const maxDuration = 180;
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withPublicApi(request, async ({ db }) => {
    const { id } = await context.params;
    const { link, podcast } = await publicPodcast(db, id, undefined, new URL(request.url).searchParams.get("language"));
    const image = await podcastCover(podcast, { aiEnabled: await hasFlowcyAccess(link.ownerId) });
    return new Response(image.bytes as BodyInit, { headers: { "content-type": image.contentType,
      "cache-control": "private, no-store", "x-content-type-options": "nosniff" } });
  });
}
