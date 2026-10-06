import { optionalApiPrincipal } from "@/lib/auth/bearer";
import type { SummaryRow } from "@/lib/db/schema";
import { getDatabase } from "@/lib/db/client";
import { resolveShareKey } from "@/lib/services/share-access";
import { getObjectStore, publicObjectUrl } from "@/lib/storage/r2";
import { ApiError, errorResponse, notFound } from "./errors";

/**
 * Serves one of a summary's stored images, at its own link or a share link's (`/s/<key>`). Public
 * summaries are cacheable for 5 minutes (so flipping to private takes effect quickly); a private
 * one is served, never cached, to its owner, through a live share link, or to a viewer it lets in.
 */
export async function serveSummaryImage(
  request: Request,
  params: Promise<{ slug: string }>,
  keyOf: (row: SummaryRow) => string | null | Promise<string | null>,
): Promise<Response> {
  try {
    const { slug } = await params;
    const principal = request.headers.has("authorization") ? await optionalApiPrincipal(request) : null;
    const resolved = await resolveShareKey(getDatabase(), slug, principal ? { id: principal.sub, email: principal.email } : null);
    const row = resolved.status === "ok" ? resolved.row : null;
    const key = row ? await keyOf(row) : null;
    if (!row || !key) throw notFound("The image does not exist");
    // Public summaries: hand off to the R2 custom domain (Cloudflare CDN) when one is configured.
    const direct = row.visibility === "public" ? publicObjectUrl(key) : null;
    if (direct) {
      return new Response(null, { status: 302, headers: { location: direct, "cache-control": "public, max-age=300, s-maxage=300" } });
    }
    let object;
    try {
      object = await getObjectStore().get(key);
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) throw notFound("The image does not exist");
      throw error;
    }
    const cacheControl = row.visibility === "public" ? "public, max-age=300, s-maxage=300" : "private, no-store";
    return new Response(Buffer.from(object.bytes), {
      headers: {
        "content-type": "image/png",
        "content-length": String(object.bytes.byteLength),
        "cache-control": cacheControl,
        ...(row.visibility === "public" ? {} : { vary: "Authorization" }),
      },
    });
  } catch (error) {
    return errorResponse(error);
  }
}
