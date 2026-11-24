import { readPublishedResume } from "@/lib/http/resume-recipient";

export const runtime = "nodejs";
export async function GET(request: Request, { params }: { params: Promise<{ slug: string; assetId: string }> }) {
  const { slug, assetId } = await params;
  return readPublishedResume(request, slug, "avatar", assetId);
}
