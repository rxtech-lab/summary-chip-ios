import { noStoreJson } from "@/lib/http/errors";
import { withPublicApi } from "@/lib/http/handler";
import { publicPodcastData } from "@/lib/services/podcast-sharing";

export const runtime = "nodejs";
export const maxDuration = 180;
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withPublicApi(request, async ({ db }) => noStoreJson(await publicPodcastData(db, (await context.params).id, new URL(request.url).searchParams.get("language"))));
}
