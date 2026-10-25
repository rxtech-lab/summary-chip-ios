import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { backgroundJob } from "@/lib/services/background-jobs";
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ job: await backgroundJob(db, principal.sub, (await context.params).id) }));
}
