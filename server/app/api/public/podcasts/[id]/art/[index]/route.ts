import { eq } from "drizzle-orm";
import { summaries } from "@/lib/db/schema";
import { notFound } from "@/lib/http/errors";
import { withPublicApi } from "@/lib/http/handler";
import { publicPodcast } from "@/lib/services/podcast-sharing";
import { getObjectStore } from "@/lib/storage/r2";

export const runtime = "nodejs";
export async function GET(request: Request, context: { params: Promise<{ id: string; index: string }> }) {
  return withPublicApi(request, async ({ db }) => {
    const { id, index } = await context.params;
    const { podcast } = await publicPodcast(db, id);
    const segment = /^\d+$/.test(index) ? podcast.segments[Number(index)] : null;
    if (!segment) throw notFound("Artwork not found");
    const [chip] = await db.select().from(summaries).where(eq(summaries.id, segment.chipId)).limit(1);
    if (!chip?.artImageKey) throw notFound("Artwork not found");
    const image = await getObjectStore().get(chip.artImageKey);
    return new Response(image.bytes as BodyInit, { headers: { "content-type": image.contentType,
      "cache-control": "private, no-store", "x-content-type-options": "nosniff" } });
  });
}
