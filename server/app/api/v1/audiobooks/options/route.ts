import { getAiProvider } from "@/lib/ai/provider";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { audiobookOptions } from "@/lib/services/audiobook-options";
import { acceptedLanguage } from "@/lib/services/translations";

/** The voices, themes and lengths the audiobook form offers. */
export async function GET(request: Request) {
  return withApiAuth(request, async () => noStoreJson(audiobookOptions(await getAiProvider(), acceptedLanguage(request))));
}
