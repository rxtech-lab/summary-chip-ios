import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { documentToMarkdown } from "@/lib/rich-document/markdown";
import { getOwnedRichDocument, getRichDocument } from "@/lib/services/rich-documents";
import { deleteSummary } from "@/lib/services/summaries";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** The document, for the owner or anyone who can read its summary. `?format=markdown` returns it as Markdown. */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const richDocument = await getRichDocument(db, id, principal.sub);
    if (new URL(request.url).searchParams.get("format") === "markdown") {
      return new Response(documentToMarkdown(richDocument.document), { headers: { "content-type": "text/markdown; charset=utf-8", "cache-control": "no-store" } });
    }
    return noStoreJson({ richDocument });
  });
}

/** Same as deleting the summary: the document row goes with it. */
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await getOwnedRichDocument(db, id, principal.sub);
    await deleteSummary(db, principal.sub, id);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  });
}
