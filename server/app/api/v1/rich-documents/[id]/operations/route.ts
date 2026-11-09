import { richDocumentOperationsRequestSchema } from "@/lib/contracts/rich-document";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { editRichDocument } from "@/lib/services/rich-documents";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** Inserts, changes, moves or removes blocks as one change. */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => richDocumentOperationsRequestSchema.parse(body));
    return noStoreJson({ richDocument: await editRichDocument(db, principal.sub, id, input) });
  });
}
