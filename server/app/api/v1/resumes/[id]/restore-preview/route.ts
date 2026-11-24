import { previewResumeRestoreSchema } from "@/lib/contracts/resume";
import { previewResumeRestore } from "@/lib/services/resumes";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await context.params;
    const input = await readJson(request, (body) => previewResumeRestoreSchema.parse(body));
    const result = await previewResumeRestore(db, principal.sub, id, input);
    return noStoreJson(result);
  });
}
