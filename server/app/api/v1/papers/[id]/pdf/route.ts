import { ApiError } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { paperPdf } from "@/lib/services/papers";

export const runtime = "nodejs";
/** Compiling a long paper with a bibliography takes a while. */
export const maxDuration = 120;

type Context = { params: Promise<{ id: string }> };

/**
 * The paper compiled to a PDF: the working copy, or `?version=` (owner only). `X-Paper-Revision`
 * says which revision it is. `422 LATEX_COMPILE_FAILED` lists the errors (`details.errors`:
 * `{ file, line, message }`) and the end of the log (`details.log`).
 */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const raw = new URL(request.url).searchParams.get("version");
    const version = raw === null ? undefined : Number(raw);
    if (version !== undefined && !(Number.isInteger(version) && version > 0)) throw new ApiError(400, "VALIDATION_ERROR", "version must be a positive integer");
    const pdf = await paperPdf(db, id, principal.sub, { version });
    return new Response(pdf.bytes as BodyInit, {
      headers: {
        "content-type": "application/pdf",
        "content-disposition": `inline; filename="paper.pdf"; filename*=UTF-8''${encodeURIComponent(pdf.filename)}`,
        "cache-control": "no-store",
        ...(pdf.revision === null ? {} : { "x-paper-revision": String(pdf.revision) }),
      },
    });
  }, { feature: "papers" });
}
