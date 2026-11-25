import { chatUploadSchema, MAX_CHAT_FILE_BYTES } from "@/lib/ai/chat-attachments";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createUpload, getCompletedUpload } from "@/lib/services/uploads";
import { getObjectStore } from "@/lib/storage/r2";

export const runtime = "nodejs";

/** A local Mac agent can read its user's encrypted attachment for the duration of a turn. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const key = new URL(request.url).searchParams.get("key") ?? "";
    const store = getObjectStore();
    const { mimeType } = await getCompletedUpload(db, principal.sub, key, store, MAX_CHAT_FILE_BYTES, "chat-uploads");
    const { bytes } = await store.get(key);
    return new Response(new Blob([Buffer.from(bytes)]).stream(), { headers: {
      "content-type": mimeType, "cache-control": "private, no-store", "x-content-type-options": "nosniff",
      "content-disposition": "attachment",
    } });
  });
}

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, value => chatUploadSchema.parse(value));
    const upload = await createUpload(db, principal.sub, input, getObjectStore(), "chat-uploads");
    return noStoreJson(upload, { status: 201 });
  });
}
