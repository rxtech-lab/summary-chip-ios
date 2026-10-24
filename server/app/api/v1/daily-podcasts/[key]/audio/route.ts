import { podcastDaySchema, podcastLanguageQuery } from "@/lib/contracts/daily-podcast";
import { withApiAuth } from "@/lib/http/handler";
import { dailyPodcastRecording } from "@/lib/services/daily-podcast";

export const runtime = "nodejs";
export const maxDuration = 60;
export async function GET(request: Request, context: { params: Promise<{ key: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { key } = await context.params;
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    const language = podcastLanguageQuery(query);
    const audio = await dailyPodcastRecording(db, principal.sub, day, key, undefined, language);
    return new Response(audio.bytes as BodyInit, { headers: {
      "content-type": "audio/mpeg", "cache-control": "private, no-store",
      "content-length": String(audio.bytes.length),
      "content-disposition": `attachment; filename="podcast-${key}${language ? `-${language}` : ""}.mp3"`,
    } });
  });
}
