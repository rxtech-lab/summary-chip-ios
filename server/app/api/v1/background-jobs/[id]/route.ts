import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { backgroundJob, deleteBackgroundJob } from "@/lib/services/background-jobs";
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ job: await backgroundJob(db, principal.sub, (await context.params).id) }));
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    await deleteBackgroundJob(db, principal.sub, (await context.params).id);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  });
}
