import type { Database } from "@/lib/db/client";
import { renderPdf } from "@/lib/pdf/browser-pdf";
import type { TranslationLanguage } from "@/lib/contracts/api";
import { REPORT_LANGUAGES, renderTripReport, type ReportLanguage } from "@/lib/pdf/trip-report";
import { activeTripDocument } from "./trip-document";
import { readSavedTripDocument } from "./trips";

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
 * may export it; it's free. It's in the language the viewer reads the trip in (the owner's chosen
 * language, else `accepted`), from the translations already saved, and follows the plan options they picked; the report's labels follow that
 * language when they exist in it, else `labels` (the app's language).
 */
export async function exportTripPdf(db: Database, id: string, viewerId: string, labels: ReportLanguage, accepted: TranslationLanguage | null): Promise<TripPdf> {
  const { document: saved, language, planSelections } = await readSavedTripDocument(db, id, viewerId, accepted);
  const reportLanguage = REPORT_LANGUAGES.find((candidate) => candidate === language) ?? labels;
  // The report follows the plan options the viewer picked, like the app does.
  const document = activeTripDocument(saved, planSelections);
  const { html, page } = renderTripReport(document, reportLanguage);
  return { bytes: await renderPdf(html, page), filename: tripPdfFilename(document.title) };
}
