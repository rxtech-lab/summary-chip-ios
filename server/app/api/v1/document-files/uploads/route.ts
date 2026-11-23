import { createFileUploadSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { DOCUMENT_FILE_MAX_BYTES } from "@/lib/services/document-files";
import { createUpload } from "@/lib/services/uploads";

export const runtime = "nodejs";

const attachmentUploadSchema = createFileUploadSchema.extend({
  byteSize: createFileUploadSchema.shape.byteSize.max(DOCUMENT_FILE_MAX_BYTES),
});

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => attachmentUploadSchema.parse(body));
    return noStoreJson(await createUpload(db, principal.sub, input), { status: 201 });
  });
}
