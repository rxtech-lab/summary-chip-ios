import { podcastRenderSchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { podcastRenderStatus, startPodcastRender } from "@/lib/services/podcast-render";
export const runtime = "nodejs";
type Context = { params: Promise<{ key: string }> };
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key } = await context.params;
    const { day, language, resolution } = await readJson(request, value => podcastRenderSchema.parse(value));
    return noStoreJson(await startPodcastRender(db, principal.sub, day, key, resolution, language));
  });
}
export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { key } = await context.params;
    const query = new URL(request.url).searchParams;
    const { day, language, resolution } = podcastRenderSchema.parse({ day: { start: query.get("start"), end: query.get("end") },
      language: query.get("language") ?? undefined, resolution: query.has("resolution") ? Number(query.get("resolution")) : undefined });
    return noStoreJson(await podcastRenderStatus(db, principal.sub, day, key, resolution, language));
  });
}
