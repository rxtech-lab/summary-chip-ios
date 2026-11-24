import { z } from "zod";
import { resumeLanguageSchema } from "@/lib/contracts/resume";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { previewResumeVariant } from "@/lib/services/resumes";

const schema = z.strictObject({
  sourceRevisionToken: z.string().min(1).max(1000),
  language: resumeLanguageSchema.optional(),
});
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await context.params;
    const input = await readJson(request, (body) => schema.parse(body));
    return noStoreJson(await previewResumeVariant(db, principal.sub, id, input));
  });
}
