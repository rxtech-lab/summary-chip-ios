import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { linkedVideoPodcasts } from "@/lib/services/daily-podcast";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await context.params;
    return noStoreJson({ items: await linkedVideoPodcasts(db, principal.sub, id) });
  });
}
