import { restoreResumeSchema } from "@/lib/contracts/resume";
import { restoreResume } from "@/lib/services/resumes";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await context.params;
    const input = await readJson(request, (body) => restoreResumeSchema.parse(body));
    const result = await restoreResume(db, principal.sub, id, input);
    return noStoreJson(result);
  });
}
