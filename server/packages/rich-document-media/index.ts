import sharp from "sharp";

/** Shared image policy for Markdown documents: auto-orient, strip metadata, bound pixels and encode WebP. */
export async function compressDocumentImage(bytes: Uint8Array) {
  return sharp(bytes, { limitInputPixels: 8192 * 8192, failOn: "error" })
    .rotate().resize({ width: 2048, height: 2048, fit: "inside", withoutEnlargement: true })
    .webp({ quality: 82 }).toBuffer({ resolveWithObject: true });
}
