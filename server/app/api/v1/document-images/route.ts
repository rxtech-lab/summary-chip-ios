import { z } from "zod";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { finishDocumentImageUpload } from "@/lib/services/document-images";
export const runtime = "nodejs";
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => z.object({ uploadKey: z.string().min(1).max(300) }).parse(body));
    return noStoreJson({ image: await finishDocumentImageUpload(db, principal.sub, input.uploadKey) });
  });
}
