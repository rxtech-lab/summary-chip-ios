import { serveSummaryImage } from "@/lib/http/summary-image";

export const runtime = "nodejs";

/** The OG artwork without text, for tiles that draw their own title (see `serveSummaryImage`). */
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  return serveSummaryImage(request, params, (row) => row.artImageKey);
}
