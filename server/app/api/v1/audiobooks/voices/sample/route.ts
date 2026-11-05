import { audiobookVoiceSampleSchema } from "@/lib/contracts/audiobook";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { voiceSampleUrl } from "@/lib/services/audiobook-voices";

export const runtime = "nodejs";
export const maxDuration = 60;
/** A short private link to a voice's sample, drawn once and then served from storage. Free. */
export async function GET(request: Request) {
  return withApiAuth(request, async () => {
    const query = new URL(request.url).searchParams;
    const input = audiobookVoiceSampleSchema.parse({ voice: query.get("voice"), language: query.get("language") ?? undefined });
    return noStoreJson(await voiceSampleUrl(input.voice, input.language));
  });
}
