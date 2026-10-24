import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { libraryPodcast } from "@/lib/services/daily-podcast";
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await context.params;
    return noStoreJson({ podcast: await libraryPodcast(db, principal.sub, id) });
  });
}
