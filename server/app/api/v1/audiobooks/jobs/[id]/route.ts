import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { audiobookJob, dismissAudiobookJob } from "@/lib/services/audiobooks";

/** One generation or translation's progress. Free; polled by the app. */
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ job: await audiobookJob(db, principal.sub, (await context.params).id) }));
}
/** Dismisses a failed job from the library. */
export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    await dismissAudiobookJob(db, principal.sub, (await context.params).id);
    return new Response(null, { status: 204 });
  });
}
