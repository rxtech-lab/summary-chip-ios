import { z } from "zod";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { finishDocumentFileUpload } from "@/lib/services/document-files";
export const runtime = "nodejs";
/** Finalizes a direct presigned upload into a lasting attachment URL. Only JSON reaches this route. */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => z.object({
      uploadKey: z.string().min(1).max(300),
      name: z.string().trim().min(1).max(200).nullish(),
    }).parse(body));
    return noStoreJson({ file: await finishDocumentFileUpload(db, principal.sub, input.uploadKey, input.name) });
  });
}
