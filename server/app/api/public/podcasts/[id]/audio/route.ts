import { withPublicApi } from "@/lib/http/handler";
import { publicPodcast } from "@/lib/services/podcast-sharing";
import { dailyPodcastRecording } from "@/lib/services/daily-podcast";

export const runtime = "nodejs";
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withPublicApi(request, async ({ db }) => {
    const { link } = await publicPodcast(db, (await context.params).id);
    const audio = await dailyPodcastRecording(db, link.ownerId, link.day, link.episodeKey);
    const size = audio.bytes.length;
    const headers = new Headers({ "content-type": "audio/mpeg", "cache-control": "private, no-store",
      "accept-ranges": "bytes", "content-length": String(size), "x-content-type-options": "nosniff" });
    const range = request.headers.get("range");
    if (!range) return new Response(audio.bytes as BodyInit, { headers });
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    const start = match?.[1] ? Number(match[1]) : Math.max(0, size - Number(match?.[2]));
    const end = match?.[1] && match[2] ? Math.min(size - 1, Number(match[2])) : size - 1;
    if (!match || (!match[1] && !match[2]) || !Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) {
      headers.set("content-range", `bytes */${size}`);
      headers.set("content-length", "0");
      return new Response(null, { status: 416, headers });
    }
    headers.set("content-range", `bytes ${start}-${end}/${size}`);
    headers.set("content-length", String(end - start + 1));
    return new Response(audio.bytes.slice(start, end + 1) as BodyInit, { status: 206, headers });
  });
}
