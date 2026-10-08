import { optionalApiPrincipal } from "@/lib/auth/bearer";
import { getDatabase } from "@/lib/db/client";
import { errorResponse, notFound } from "@/lib/http/errors";
import { resolveShareKey, shareViewerFor } from "@/lib/services/share-access";
import { getObjectStore } from "@/lib/storage/r2";

export const runtime = "nodejs";

/** 302 to a short-lived signed URL of the uploaded PDF, for whoever `/s/<key>` lets in (see `resolveShareKey`). */
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  try {
    const { slug } = await params;
    const principal = request.headers.has("authorization") ? await optionalApiPrincipal(request) : null;
    const resolved = await resolveShareKey(getDatabase(), slug, shareViewerFor(principal, request));
    const row = resolved.status === "ok" ? resolved.row : null;
    if (!row || row.sourceType !== "pdf" || !row.sourceFileKey) throw notFound("The source file does not exist");
    const filename = `${(row.sourceTitle || row.title).replace(/[^\p{L}\p{N} ._-]/gu, "").trim().slice(0, 80) || "document"}.pdf`;
    const signed = await getObjectStore().signedGet(row.sourceFileKey, { filename, inline: true, expiresInSeconds: 300 });
    return new Response(null, {
      status: 302,
      headers: {
        location: signed.url,
        "cache-control": row.visibility === "public" ? "public, max-age=60" : "private, no-store",
      },
    });
  } catch (error) {
    return errorResponse(error);
  }
}
