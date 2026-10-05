import type { Database } from "@/lib/db/client";
import { renderPdf } from "@/lib/pdf/browser-pdf";
import { renderTripReport, type ReportLanguage } from "@/lib/pdf/trip-report";
import { getTrip } from "./trips";

export interface TripPdf {
  bytes: Uint8Array;
  filename: string;
}

/** A file name from the trip's title: letters (any script), digits and dashes. */
export function tripPdfFilename(title: string): string {
  const base = title.normalize("NFKC").replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "").slice(0, 80);
  return `${base || "trip"}.pdf`;
}

/**
 * `GET /api/v1/trips/:id/pdf`: the trip as an A4 report printed by Cloudflare Browser Run, with the
 * trip's title and dates in the header and page numbers in the footer. Anyone who can open the trip
 * may export it; it's free.
 */
export async function exportTripPdf(db: Database, id: string, viewerId: string, language: ReportLanguage): Promise<TripPdf> {
  const trip = await getTrip(db, id, viewerId);
  const { html, page } = renderTripReport(trip.document, language);
  return { bytes: await renderPdf(html, page), filename: tripPdfFilename(trip.document.title) };
}
