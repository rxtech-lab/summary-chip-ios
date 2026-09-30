import { ApiError } from "@/lib/http/errors";
import { normalizeWhitespace } from "./html";

export function looksLikePdf(bytes: Uint8Array): boolean {
  return bytes.byteLength > 4 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
}

/** Text of a PDF via unpdf (serverless pdf.js). Image-only PDFs produce a clear 422. */
export async function extractPdfText(bytes: Uint8Array): Promise<{ text: string; title: string | null; pages: number }> {
  if (!looksLikePdf(bytes)) throw new ApiError(422, "INVALID_PDF", "The uploaded file is not a PDF");
  const { extractText, getDocumentProxy, getMeta } = await import("unpdf");
  let pdf;
  try {
    pdf = await getDocumentProxy(new Uint8Array(bytes));
  } catch {
    throw new ApiError(422, "INVALID_PDF", "The PDF could not be opened (it may be damaged or password protected)");
  }
  const { text, totalPages } = await extractText(pdf, { mergePages: true });
  let title: string | null = null;
  try {
    const metaInfo = await getMeta(pdf);
    const raw = metaInfo.info?.Title;
    title = typeof raw === "string" && raw.trim() ? raw.trim() : null;
  } catch {
    title = null;
  }
  const normalized = normalizeWhitespace(text);
  if (normalized.replace(/\s/g, "").length < 20) {
    throw new ApiError(422, "PDF_NO_TEXT", "This PDF has no extractable text (it looks like a scanned PDF). Try a text-based PDF.");
  }
  return { text: normalized, title, pages: totalPages };
}
