import { createRichDocumentSchema } from "@/lib/contracts/rich-document";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createRichDocument, listRichDocuments } from "@/lib/services/rich-documents";

export const runtime = "nodejs";
/** Creating a document designs and renders its cover. */
export const maxDuration = 120;

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson(await listRichDocuments(db, principal.sub)));
}

/** `{document}` or `{markdown, title?}`, plus `visibility`. */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createRichDocumentSchema.parse(body));
    return noStoreJson({ richDocument: await createRichDocument(db, principal, input) }, { status: 201 });
  });
}
