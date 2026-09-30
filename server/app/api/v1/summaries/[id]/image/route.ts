import { regenerateImageSchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { regenerateImage } from "@/lib/services/summaries";

export const runtime = "nodejs";
export const maxDuration = 120;

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const { imageStyle } = await readJson(request, (body) => regenerateImageSchema.parse(body));
    return noStoreJson(await regenerateImage(db, principal.sub, id, imageStyle));
  });
}
