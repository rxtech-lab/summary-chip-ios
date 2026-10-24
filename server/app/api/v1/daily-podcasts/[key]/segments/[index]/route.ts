import { podcastDaySchema } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { dailyPodcastAudio } from "@/lib/services/daily-podcast";

export const runtime = "nodejs";
export async function GET(request: Request, context: { params: Promise<{ key: string; index: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { key, index } = await context.params;
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    const audio = await dailyPodcastAudio(db, principal.sub, day, key, /^\d+$/.test(index) ? Number(index) : -1);
    return new Response(audio.bytes as BodyInit, { headers: {
      "content-type": audio.contentType, "cache-control": "private, no-store",
    } });
  });
}
