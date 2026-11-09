import { z } from "zod";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { getOwnedRichDocument } from "@/lib/services/rich-documents";
import { storeDocumentImage } from "@/lib/services/trip-images";

export const runtime = "nodejs";
export const maxDuration = 60;

type Context = { params: Promise<{ id: string }> };

const bodySchema = z.object({ uploadKey: z.string().trim().min(1).max(300) }).strict();

/**
 * Turns a finished presigned upload (`POST /api/v1/uploads`, then PUT to S3) into a lasting image URL
 * for an image block or a video's poster. The bytes never pass through this function's 4.5 MB body.
 */
export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => bodySchema.parse(body));
    const { summary } = await getOwnedRichDocument(db, id, principal.sub);
    return noStoreJson({ image: await storeDocumentImage(db, principal.sub, summary.id, input) }, { status: 201 });
  });
}
