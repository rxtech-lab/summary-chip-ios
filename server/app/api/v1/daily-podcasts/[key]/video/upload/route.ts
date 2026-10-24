import { podcastVideoUploadSchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createPodcastVideoUpload } from "@/lib/services/podcast-video";

export const runtime = "nodejs";
type Context = { params: Promise<{ key: string }> };

/** A presigned PUT for the app's MP4 render of the current composition. */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key } = await context.params;
    const input = await readJson(request, body => podcastVideoUploadSchema.parse(body));
    return noStoreJson(await createPodcastVideoUpload(db, principal.sub, input, key), { status: 201 });
  });
}
