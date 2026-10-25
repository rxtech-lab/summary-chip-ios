import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { listBackgroundJobs } from "@/lib/services/background-jobs";
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson(
    await listBackgroundJobs(db, principal.sub, new URL(request.url).searchParams.get("cursor") ?? undefined),
  ));
}
