import { notFound } from "@/lib/http/errors";
import { withPublicApi } from "@/lib/http/handler";
import { getObjectStore } from "@/lib/storage/r2";
import { documentFileKeyFor } from "@/lib/services/document-files";

export const runtime = "nodejs";

/** Stable capability URL. The client downloads the bytes directly from storage. */
export async function GET(request: Request, { params }: { params: Promise<{ token: string; name: string }> }) {
  return withPublicApi(request, async () => {
    const { token, name } = await params;
    const key = documentFileKeyFor(token, name);
    if (!key) throw notFound();
    const { url } = await getObjectStore().signedGet(key, { filename: name });
    return new Response(null, {
      status: 307,
      headers: { location: url, "cache-control": "private, no-store", "referrer-policy": "no-referrer" },
    });
  });
}
