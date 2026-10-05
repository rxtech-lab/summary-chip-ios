import { browserRenderingConfig } from "@/lib/extract/browser";
import { ApiError } from "@/lib/http/errors";
import { prepareReportImages } from "./report-images";

/**
 * Cloudflare Browser Run's /pdf endpoint (account id is the path segment): prints HTML in headless
 * Chromium and returns the PDF bytes in one synchronous call. Same credentials as link crawling.
 */
const PDF_ENDPOINT = "https://api.cloudflare.com/client/v4/accounts/%s/browser-run/pdf";

const PDF_TIMEOUT_MS = 90_000;
const PDF_MAX_BYTES = 32 * 1024 * 1024;

/** Bound memory use and cancel oversized or failed response streams. */
async function readPdfResponse(response: Response): Promise<Uint8Array> {
  const limit = response.ok ? PDF_MAX_BYTES : 4096;
  if (response.ok && Number(response.headers.get("content-length")) > limit) {
    await response.body?.cancel().catch(() => undefined);
    throw new ApiError(502, "PDF_RENDER_FAILED", "The PDF is too large to download. Please reduce the number of photos and try again.");
  }
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (size + value.byteLength > limit) {
        if (response.ok) throw new ApiError(502, "PDF_RENDER_FAILED", "The PDF is too large to download. Please reduce the number of photos and try again.");
        chunks.push(value.subarray(0, limit - size));
        size = limit;
        break;
      }
      size += value.byteLength;
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => undefined);
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export interface PdfPageOptions {
  /** Repeated at the top of every page; Chromium fills `.pageNumber`, `.totalPages`, `.title` and `.date`. */
  headerTemplate: string;
  footerTemplate: string;
  /** CSS lengths (`"24mm"`); the header and footer draw inside the top and bottom margins. */
  margin: { top: string; bottom: string; left: string; right: string };
}

/** Whether PDFs can be rendered: CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN (Browser Rendering - Edit) are set. */
export function pdfRenderingConfigured(): boolean {
  return browserRenderingConfig() !== null;
}

/**
 * Prints an A4 PDF with the page header and footer. Photos are embedded as bounded JPEGs before
 * printing so full-resolution originals cannot inflate the PDF download.
 * Fails with `503 PDF_UNAVAILABLE` when not configured and `502 PDF_RENDER_FAILED` when the render fails.
 */
export async function renderPdf(html: string, page: PdfPageOptions): Promise<Uint8Array> {
  const config = browserRenderingConfig();
  if (!config) throw new ApiError(503, "PDF_UNAVAILABLE", "PDF export is not available right now.");
  const startedAt = Date.now();
  try {
    const preparedHtml = await prepareReportImages(html);
    const response = await fetch(PDF_ENDPOINT.replace("%s", encodeURIComponent(config.accountId)), {
      method: "POST",
      signal: AbortSignal.timeout(PDF_TIMEOUT_MS),
      headers: { authorization: `Bearer ${config.apiToken}`, "content-type": "application/json" },
      body: JSON.stringify({
        html: preparedHtml,
        gotoOptions: { waitUntil: "networkidle0", timeout: 60_000 },
        pdfOptions: {
          format: "a4",
          printBackground: true,
          displayHeaderFooter: true,
          headerTemplate: page.headerTemplate,
          footerTemplate: page.footerTemplate,
          margin: page.margin,
        },
      }),
    });
    // Fetch resolves once headers arrive; socket failures can happen while reading the body too.
    const bytes = await readPdfResponse(response);
    const isPdf = bytes.length > 4 && String.fromCharCode(...bytes.subarray(0, 5)) === "%PDF-";
    if (!response.ok || !isPdf) {
      console.warn(`[pdf] browser run failed: HTTP ${response.status}`);
      throw new ApiError(502, "PDF_RENDER_FAILED", "The PDF could not be rendered. Please try again.");
    }
    if (process.env.NODE_ENV !== "test") console.info(`[pdf] rendered ${bytes.length} bytes in ${Date.now() - startedAt}ms`);
    return bytes;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    console.warn("[pdf] browser run failed:", (error as Error).message);
    throw new ApiError(502, "PDF_RENDER_FAILED", "The PDF download was interrupted. Please try exporting again.");
  }
}
