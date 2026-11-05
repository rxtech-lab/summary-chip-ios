import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listAudiobookJobs, listAudiobookPlans } from "@/lib/services/audiobooks";

/** The owner's unconfirmed plans and the audiobooks being made. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ plans: await listAudiobookPlans(db, principal.sub), jobs: await listAudiobookJobs(db, principal.sub) }));
}
