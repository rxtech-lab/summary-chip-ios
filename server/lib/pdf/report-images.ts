import { parseHTML } from "linkedom";
import sharp from "sharp";
import { fetchPublicDocument } from "@/lib/extract/fetch";

const IMAGE_MAX_BYTES = 15 * 1024 * 1024;
const JPEG_MAX_BYTES = 256 * 1024;
const TOTAL_JPEG_MAX_BYTES = 12 * 1024 * 1024;
const PREPARE_TIMEOUT_MS = 20_000;

/**
 * CSS sizing doesn't reduce the image bytes embedded by Chromium. Fetch each unique photo once,
 * check redirects with the public-document fetcher, and embed a print-sized JPEG instead of the
 * original. Keep a source link when an image is unavailable or exceeds the export's budget.
 */
export async function prepareReportImages(html: string): Promise<string> {
  const { document } = parseHTML(html) as unknown as { document: Document };
  const images = Array.from(document.querySelectorAll("img"));
  if (!images.length) return html;
  const sources = [...new Set(images.map((image) => image.getAttribute("src") ?? ""))];
  const occurrences = new Map<string, number>();
  for (const image of images) {
    const source = image.getAttribute("src") ?? "";
    occurrences.set(source, (occurrences.get(source) ?? 0) + 1);
  }
  const prepared = new Map<string, string>();
  const deadline = Date.now() + PREPARE_TIMEOUT_MS;
  let next = 0;
  let totalBytes = 0;
  let failed = 0;

  async function worker() {
    while (next < sources.length) {
      const source = sources[next++];
      const remaining = deadline - Date.now();
      if (remaining <= 0 || totalBytes >= TOTAL_JPEG_MAX_BYTES) break;
      try {
        if (new URL(source).protocol !== "https:") continue;
        const fetched = await fetchPublicDocument(source, {
          maxBytes: IMAGE_MAX_BYTES, timeoutMs: Math.min(8_000, remaining), accept: "image/*",
        });
        if (!fetched.contentType.startsWith("image/") && fetched.contentType !== "application/octet-stream") continue;
        let jpeg = await sharp(fetched.bytes, { limitInputPixels: 8192 * 8192, failOn: "error" })
          .timeout({ seconds: Math.max(1, Math.ceil((deadline - Date.now()) / 1000)) })
          .rotate()
          .resize({ width: 1440, height: 1440, fit: "inside", withoutEnlargement: true })
          .flatten({ background: "#ffffff" })
          .jpeg({ quality: 76 })
          .toBuffer();
        if (jpeg.length > JPEG_MAX_BYTES) {
          jpeg = await sharp(jpeg).resize({ width: 960, height: 960, fit: "inside", withoutEnlargement: true })
            .jpeg({ quality: 60 }).toBuffer();
        }
        // Repeated photos also repeat their data URL in the HTML request body.
        const embeddedBytes = jpeg.length * (occurrences.get(source) ?? 1);
        if (Date.now() > deadline || jpeg.length > JPEG_MAX_BYTES || totalBytes + embeddedBytes > TOTAL_JPEG_MAX_BYTES) continue;
        totalBytes += embeddedBytes;
        prepared.set(source, `data:image/jpeg;base64,${jpeg.toString("base64")}`);
      } catch {
        // An optional photo must not prevent exporting the itinerary.
        failed += 1;
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(4, sources.length) }, worker));
  const language = document.documentElement.lang;
  const label = language.startsWith("zh") ? "照片" : "Photo";
  for (const image of images) {
    const source = image.getAttribute("src") ?? "";
    const jpeg = prepared.get(source);
    if (jpeg) image.setAttribute("src", jpeg);
    else {
      const link = document.createElement("a");
      try {
        if (new URL(source).protocol === "https:") link.setAttribute("href", source);
      } catch { /* No valid source URL. */ }
      link.textContent = image.getAttribute("alt") || label;
      image.replaceWith(link);
    }
  }
  if (process.env.NODE_ENV !== "test") {
    console.info(`[pdf] photos: ${prepared.size}/${sources.length} prepared, ${totalBytes} JPEG bytes, ${failed} failed`);
  }
  return document.toString();
}
