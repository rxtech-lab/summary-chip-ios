import { isBotUserAgent } from "@/lib/bots";
import { runAfter } from "@/lib/http/after";
import { notFound } from "@/lib/http/errors";
import { withPublicApi } from "@/lib/http/handler";
import { findPublicSummaryBySlug, incrementViewCount, readSummaryJson } from "@/lib/services/summaries";
import { acceptedLanguage } from "@/lib/services/translations";

export const runtime = "nodejs";
/** Translating the source document continues after the response (`after`). */
export const maxDuration = 300;

/** Anonymous read used by the App Clip, in the reader's `Accept-Language`. Private/expired/missing → 404. */
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  return withPublicApi(request, async ({ db }) => {
    const { slug } = await params;
    const row = await findPublicSummaryBySlug(db, slug);
    if (!row) throw notFound();
    if (!isBotUserAgent(request.headers.get("user-agent"))) {
      runAfter(() => incrementViewCount(db, row.id));
    }
    return Response.json(await readSummaryJson(db, row, null, acceptedLanguage(request)), {
      headers: { "cache-control": "public, max-age=0, must-revalidate", vary: "Accept-Language" },
    });
  });
}
