import { readPublishedResume } from "@/lib/http/resume-recipient";

export const runtime = "nodejs";
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  return readPublishedResume(request, slug, "pdf");
}
