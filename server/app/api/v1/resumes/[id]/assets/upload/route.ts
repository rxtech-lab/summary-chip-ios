import { withApiAuth } from "@/lib/http/handler";
import { readJson, noStoreJson } from "@/lib/http/errors";
import { stageResumeAvatar, avatarUploadSchema } from "@/lib/services/resume-outputs";

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await params;
    return noStoreJson(
      await stageResumeAvatar(
        db,
        principal.sub,
        id,
        await readJson(request, (value) => avatarUploadSchema.parse(value)),
      ),
    );
  });
}
