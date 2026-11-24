import { withApiAuth } from "@/lib/http/handler";
import { getOwnerAvatar } from "@/lib/services/resume-outputs";

export async function GET(request: Request, { params }: { params: Promise<{ id: string; assetId: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id, assetId } = await params;
    return new Response(new Uint8Array(await getOwnerAvatar(db, principal.sub, id, assetId)), {
      headers: { "content-type": "image/jpeg", "cache-control": "private, no-store" },
    });
  });
}
