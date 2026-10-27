import { z } from "zod";
import { podcastDaySchema, podcastLanguageSchema } from "@/lib/contracts/daily-podcast";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { podcastInLanguage } from "@/lib/services/daily-podcast";
import { generatePodcastSummary } from "@/lib/services/podcast-summary";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 120;
const schema = z.object({ day: podcastDaySchema, language: podcastLanguageSchema.optional() }).strict();
export async function POST(request: Request, context: { params: Promise<{ key: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { key } = await context.params;
    const { day, language } = await readJson(request, body => schema.parse(body));
    const podcast = await generatePodcastSummary(db, principal.sub, day, key,
      { billingEnvironment: await billingEnvironment(request, principal) });
    return noStoreJson({ podcast: podcastInLanguage(podcast, language) });
  });
}
