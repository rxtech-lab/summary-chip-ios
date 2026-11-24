import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { RESUME_TEMPLATES } from "@/lib/resume/render";

export async function GET(request: Request) {
  return withApiAuth(request, async () => noStoreJson({ items: RESUME_TEMPLATES }));
}
