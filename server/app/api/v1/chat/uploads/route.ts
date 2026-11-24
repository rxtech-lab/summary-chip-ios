import { chatUploadSchema } from "@/lib/ai/chat-attachments";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createUpload } from "@/lib/services/uploads";
import { getObjectStore } from "@/lib/storage/r2";

export const runtime = "nodejs";

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, value => chatUploadSchema.parse(value));
    const upload = await createUpload(db, principal.sub, input, getObjectStore(), "chat-uploads");
    return noStoreJson(upload, { status: 201 });
  });
}
