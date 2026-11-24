import { and, eq } from "drizzle-orm";
import { summaries } from "@/lib/db/schema";
import { notFound } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { renderResumeCover } from "@/lib/og/resume-cover";

export const runtime = "nodejs";

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await params;
    const [resume] = await db.select({ id: summaries.id }).from(summaries)
      .where(and(eq(summaries.id, id), eq(summaries.ownerId, principal.sub), eq(summaries.kind, "resume")))
      .limit(1);
    if (!resume) throw notFound("Résumé not found");

    return new Response(Buffer.from(await renderResumeCover(resume.id)), {
      headers: {
        "content-type": "image/png",
        "cache-control": "private, no-store",
        vary: "Authorization",
      },
    });
  });
}
