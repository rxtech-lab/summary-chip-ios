import { resumeTargetSchema } from "@/lib/contracts/resume";
import { getResume } from "@/lib/services/resumes";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await context.params;
    const input = resumeTargetSchema.parse(Object.fromEntries(new URL(request.url).searchParams));
    const result = await getResume(db, principal.sub, id, input);
    return noStoreJson(result);
  });
}
