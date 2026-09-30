import { isBotUserAgent } from "@/lib/bots";
import { runAfter } from "@/lib/http/after";
import { notFound } from "@/lib/http/errors";
import { withPublicApi } from "@/lib/http/handler";
import { toSummaryJson } from "@/lib/services/serialize";
import { findPublicSummaryBySlug, incrementViewCount } from "@/lib/services/summaries";

export const runtime = "nodejs";

/** Anonymous read used by the App Clip. Private/expired/missing → 404. */
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  return withPublicApi(request, async ({ db }) => {
    const { slug } = await params;
    const row = await findPublicSummaryBySlug(db, slug);
    if (!row) throw notFound();
    if (!isBotUserAgent(request.headers.get("user-agent"))) {
      runAfter(() => incrementViewCount(db, row.id));
    }
    return Response.json(toSummaryJson(row, null), {
      headers: { "cache-control": "public, max-age=0, must-revalidate" },
    });
  });
}
