import { isBotUserAgent } from "@/lib/bots";
import { runAfter } from "@/lib/http/after";
import { ApiError, notFound } from "@/lib/http/errors";
import { withPublicApi } from "@/lib/http/handler";
import { resolveShareKey } from "@/lib/services/share-access";
import { incrementViewCount, readSummaryJson } from "@/lib/services/summaries";
import { acceptedLanguage } from "@/lib/services/translations";

export const runtime = "nodejs";
/** Translating the source document continues after the response (`after`). */
export const maxDuration = 300;

/**
 * Anonymous read used by the App Clip, in the reader's `Accept-Language`, at a summary's own link or
 * a share link. Private/expired/missing → 404; an invited-only link → 403 `SIGN_IN_REQUIRED`.
 */
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  return withPublicApi(request, async ({ db }) => {
    const { slug } = await params;
    const resolved = await resolveShareKey(db, slug, null);
    if (resolved.status === "sign-in") throw new ApiError(403, "SIGN_IN_REQUIRED", "Sign in to Chippy to open this link");
    if (resolved.status !== "ok") throw notFound();
    const { row, link } = resolved;
    if (!isBotUserAgent(request.headers.get("user-agent"))) {
      runAfter(() => incrementViewCount(db, row.id));
    }
    return Response.json(await readSummaryJson(db, row, null, acceptedLanguage(request), { grantToken: link?.token ?? null }), {
      headers: { "cache-control": "public, max-age=0, must-revalidate", vary: "Accept-Language" },
    });
  });
}
