import { notFound } from "@/lib/http/errors";
import { withPublicApi } from "@/lib/http/handler";
import { getObjectStore } from "@/lib/storage/r2";
import { MINI_FILE_CACHE_CONTROL, miniFileKeyFor } from "@/lib/mini-app/files";

export const runtime = "nodejs";

/** A file stored by a Clip. The unguessable token is the capability; anything but a re-encoded JPEG is served as a download. */
export async function GET(request: Request, { params }: { params: Promise<{ token: string; name: string }> }) {
  return withPublicApi(request, async () => {
    const { token, name } = await params;
    const key = miniFileKeyFor(token, name);
    if (!key) throw notFound();
    const object = await getObjectStore().get(key);
    const inline = object.contentType === "image/jpeg";
    return new Response(object.bytes as BodyInit, {
      headers: {
        "content-type": inline ? "image/jpeg" : object.contentType,
        "cache-control": object.cacheControl ?? MINI_FILE_CACHE_CONTROL,
        "x-content-type-options": "nosniff",
        ...(inline ? {} : { "content-disposition": `attachment; filename="${name}"`, "content-security-policy": "sandbox" }),
      },
    });
  });
}
