import { getAiProvider } from "@/lib/ai/provider";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { podcastGenerationOptions } from "@/lib/services/podcast-options";
import { acceptedLanguage } from "@/lib/services/translations";

/** The languages, speaker limits and video styles the podcast generation form offers. */
export async function GET(request: Request) {
  return withApiAuth(request, async () => noStoreJson(podcastGenerationOptions(await getAiProvider(), acceptedLanguage(request))));
}
