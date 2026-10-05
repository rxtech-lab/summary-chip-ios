import { notFound } from "@/lib/http/errors";
import { withPublicApi } from "@/lib/http/handler";
import { getObjectStore } from "@/lib/storage/r2";
import { TRIP_IMAGE_CACHE_CONTROL, tripImageKeyForFile } from "@/lib/services/trip-images";

export const runtime = "nodejs";

/** A trip photo uploaded through MCP, when the bucket has no public custom domain. The unguessable file name is the capability. */
export async function GET(request: Request, { params }: { params: Promise<{ file: string }> }) {
  return withPublicApi(request, async () => {
    const key = tripImageKeyForFile((await params).file);
    if (!key) throw notFound();
    const object = await getObjectStore().get(key);
    return new Response(object.bytes as BodyInit, {
      headers: { "content-type": object.contentType, "cache-control": object.cacheControl ?? TRIP_IMAGE_CACHE_CONTROL, "x-content-type-options": "nosniff" },
    });
  });
}
