import { eq } from "drizzle-orm";
import { paperRenderingSchema } from "@/lib/contracts/paper-rendering";
import { papers } from "@/lib/db/schema";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { getOwnedPaper, getPaper } from "@/lib/services/papers";

export const runtime = "nodejs";

/** Layout is separate from source revisions and never invalidates translated prose. */
export async function PUT(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await getOwnedPaper(db, id, principal.sub);
    const style = await readJson(request, (body) => paperRenderingSchema.parse(body));
    await db.update(papers).set({ renderingOptions: style }).where(eq(papers.summaryId, id));
    return noStoreJson({ paper: await getPaper(db, id, principal.sub, {}) });
  }, { feature: "papers" });
}
