import { createUploadSchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createUpload } from "@/lib/services/uploads";

export const runtime = "nodejs";

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createUploadSchema.parse(body));
    return noStoreJson(await createUpload(db, principal.sub, input), { status: 201 });
  });
}
