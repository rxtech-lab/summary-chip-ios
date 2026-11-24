import { z } from "zod";
import { withApiAuth } from "@/lib/http/handler";
import { readJson, noStoreJson } from "@/lib/http/errors";
import { importResumeAvatar } from "@/lib/services/resume-outputs";

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await params;
    const { uploadId } = await readJson(request, (value) =>
      z.strictObject({ uploadId: z.string().min(1).max(1024) }).parse(value),
    );
    return noStoreJson(await importResumeAvatar(db, principal.sub, id, uploadId));
  });
}
