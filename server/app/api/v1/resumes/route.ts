import { createResumeSchema } from "@/lib/contracts/resume";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createResume, listResumes } from "@/lib/services/resumes";

export async function GET(request: Request) {
  return withApiAuth(request, async ({ db, principal }) =>
    noStoreJson({ resumes: await listResumes(db, principal.sub) }),
  );
}
export async function POST(request: Request) {
  return withApiAuth(request, async ({ db, principal }) =>
    noStoreJson(
      await createResume(db, principal.sub, await readJson(request, (body) => createResumeSchema.parse(body))),
      { status: 201 },
    ),
  );
}
