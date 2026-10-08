import { z } from "zod";
import { paperPathSchema } from "@/lib/contracts/paper";
import { withApiAuth } from "@/lib/http/handler";
import { getPaperAsset } from "@/lib/services/papers";

export const runtime = "nodejs";
const querySchema = z.object({ path: paperPathSchema, version: z.coerce.number().int().positive().optional() });

export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const query = querySchema.parse(Object.fromEntries(new URL(request.url).searchParams));
    const asset = await getPaperAsset(db, id, principal.sub, query.path, query.version);
    return new Response(new Uint8Array(asset.bytes), { headers: {
      "content-type": asset.contentType, "cache-control": "private, no-store", "x-content-type-options": "nosniff",
    } });
  }, { feature: "papers" });
}
