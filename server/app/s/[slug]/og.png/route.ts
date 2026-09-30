import { serveSummaryImage } from "@/lib/http/summary-image";

export const runtime = "nodejs";

/** The 1200×630 OG image (see `serveSummaryImage` for access and caching). */
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  return serveSummaryImage(request, params, (row) => row.ogImageKey);
}
