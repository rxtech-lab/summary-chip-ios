import { podcastDaySchema, podcastLanguageQuery } from "@/lib/contracts/daily-podcast";
import { ApiError, noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { audiobookRecordingLink } from "@/lib/services/daily-podcast";

export const runtime = "nodejs";
/** `{url, expiresAt, byteSize}` for an audiobook's complete recording; 404 for ordinary episodes, which download from `audio`. */
export async function GET(request: Request, context: { params: Promise<{ key: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const query = new URL(request.url).searchParams;
    const day = podcastDaySchema.parse({ start: query.get("start"), end: query.get("end") });
    const link = await audiobookRecordingLink(db, principal.sub, day, (await context.params).key, undefined, podcastLanguageQuery(query));
    if (!link) throw new ApiError(404, "NOT_FOUND", "This episode has no direct link.");
    return noStoreJson(link);
  });
}
