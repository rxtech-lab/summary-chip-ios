import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { listViewedPublications } from "@/lib/services/resume-outputs";
import { shareViewerFor } from "@/lib/services/share-access";

export async function GET(request: Request) {
  return withApiAuth(request, async ({ db, principal }) =>
    noStoreJson(await listViewedPublications(db, shareViewerFor(principal, request)!)),
  );
}
