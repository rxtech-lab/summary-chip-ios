import { withApiAuth } from "@/lib/http/handler";
import { readJson } from "@/lib/http/errors";
import { renderFigureSchema, renderPaperFigure } from "@/lib/services/paper-figures";

export const runtime = "nodejs";
export const maxDuration = 120;

/**
 * `{ source, version? }` → the PDF of one TikZ or pgfplots figure of the paper drawn on its own,
 * for the native reader. Compiled once per source; `422 LATEX_COMPILE_FAILED` lists the errors.
 */
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => renderFigureSchema.parse(body));
    const figure = await renderPaperFigure(db, id, principal.sub, input);
    return new Response(new Uint8Array(figure.bytes), { headers: {
      "content-type": "application/pdf", "cache-control": "private, no-store", "x-content-type-options": "nosniff",
      "x-figure-cache": figure.cached ? "hit" : "miss",
    } });
  }, { feature: "papers" });
}
