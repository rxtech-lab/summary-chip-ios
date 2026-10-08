import { optionalApiPrincipal } from "@/lib/auth/bearer";
import { getDatabase } from "@/lib/db/client";
import { errorResponse, notFound } from "@/lib/http/errors";
import { paperPdf } from "@/lib/services/papers";
import { resolveShareKey, shareViewerFor } from "@/lib/services/share-access";

export const runtime = "nodejs";
export const maxDuration = 120;

/** A shared paper as a PDF, for whoever `/s/<key>` lets in (see `resolveShareKey`). */
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  try {
    const { slug } = await params;
    const principal = request.headers.has("authorization") ? await optionalApiPrincipal(request) : null;
    const db = getDatabase();
    const resolved = await resolveShareKey(db, slug, shareViewerFor(principal, request));
    const row = resolved.status === "ok" ? resolved.row : null;
    if (!row || row.kind !== "paper") throw notFound("The paper does not exist");
    const pdf = await paperPdf(db, row.id, principal?.sub ?? null, { viaLink: true });
    return new Response(pdf.bytes as BodyInit, {
      headers: {
        "content-type": "application/pdf",
        "content-disposition": `inline; filename="paper.pdf"; filename*=UTF-8''${encodeURIComponent(pdf.filename)}`,
        "cache-control": row.visibility === "public" ? "public, max-age=60" : "private, no-store",
      },
    });
  } catch (error) {
    return errorResponse(error);
  }
}
