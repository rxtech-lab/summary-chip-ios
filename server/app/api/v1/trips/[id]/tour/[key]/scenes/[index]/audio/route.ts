import { withApiAuth } from "@/lib/http/handler";
import { tourSceneAudio } from "@/lib/services/trip-tour";

export const runtime = "nodejs";
/** The first request for a scene reads it aloud. */
export const maxDuration = 60;

type Context = { params: Promise<{ id: string; key: string; index: string }> };

/** A tour scene's narration as MP3, stored after it's first read aloud. */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id, key, index } = await params;
    const audio = await tourSceneAudio(db, id, principal.sub, key, /^\d+$/.test(index) ? Number(index) : -1);
    return new Response(audio as BodyInit, {
      headers: { "content-type": "audio/mpeg", "content-length": String(audio.byteLength), "cache-control": "private, max-age=31536000, immutable" },
    });
  }, { feature: "trips" });
}
