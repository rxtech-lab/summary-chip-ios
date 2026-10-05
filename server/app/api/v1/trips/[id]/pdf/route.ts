import { withApiAuth } from "@/lib/http/handler";
import { reportLanguage } from "@/lib/pdf/trip-report";
import { exportTripPdf } from "@/lib/services/trip-pdf";

export const runtime = "nodejs";
// Printing waits for every photo to load.
export const maxDuration = 120;

type Context = { params: Promise<{ id: string }> };

/** The trip as an A4 PDF report (`?lang=` or `Accept-Language` picks en, zh-Hans or zh-Hant). */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const language = reportLanguage(new URL(request.url).searchParams.get("lang") ?? request.headers.get("accept-language"));
    const pdf = await exportTripPdf(db, id, principal.sub, language);
    return new Response(pdf.bytes as BodyInit, {
      headers: {
        "content-type": "application/pdf",
        "content-disposition": `attachment; filename="trip.pdf"; filename*=UTF-8''${encodeURIComponent(pdf.filename)}`,
        "cache-control": "no-store",
      },
    });
  });
}
