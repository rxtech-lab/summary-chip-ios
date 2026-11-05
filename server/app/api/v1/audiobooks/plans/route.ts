import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listAudiobookJobs, listAudiobookPlans, mergeEarlierAudiobooks } from "@/lib/services/audiobooks";

export const maxDuration = 300;
/** The owner's unconfirmed plans and the audiobooks being made. `merged` means chips changed, so the feed should reload. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const merged = await mergeEarlierAudiobooks(db, principal.sub);
    return noStoreJson({ plans: await listAudiobookPlans(db, principal.sub), jobs: await listAudiobookJobs(db, principal.sub), merged });
  });
}
