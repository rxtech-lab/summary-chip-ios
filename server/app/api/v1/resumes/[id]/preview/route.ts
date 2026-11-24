import { prepareResumePreview, resumePreviewSchema } from "@/lib/services/resume-outputs";
import { withApiAuth } from "@/lib/http/handler";
import { readJson, noStoreJson } from "@/lib/http/errors";

export const runtime = "nodejs";
export const maxDuration = 120;
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await params;
    const input = await readJson(request, (value) => resumePreviewSchema.parse(value));
    return noStoreJson(await prepareResumePreview(db, principal.sub, id, input));
  });
}
