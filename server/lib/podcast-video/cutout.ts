import sharp from "sharp";

/** Longest side of a stored cut-out: sharp at 1080p, small enough to ship with the composition. */
export const CUTOUT_MAX_SIDE = 1024;
/** Transparent padding kept around the subject after trimming. */
const PADDING = 8;

export class CutoutError extends Error {
  override name = "CutoutError";
}

export interface Cutout {
  png: Uint8Array;
  width: number;
  height: number;
}

/** How much greener than its other channels a pixel is. */
const greenness = (r: number, g: number, b: number) => g - Math.max(r, b);

/**
 * Removes the green screen behind an image model's drawing: the key colour is sampled from the border,
 * pixels near it become transparent with a soft edge, green spill is pulled out of the subject, and the
 * result is trimmed to the subject and scaled to at most `CUTOUT_MAX_SIDE`. Throws `CutoutError` when
 * the background isn't a green screen or nothing is left of the subject.
 */
export async function removeGreenScreen(image: Uint8Array): Promise<Cutout> {
  const { data, info } = await sharp(image).rotate().removeAlpha().ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const { width, height } = info;
  const pixels = new Uint8ClampedArray(data.buffer, data.byteOffset, data.byteLength);
  // The key: the median of the border pixels' greenness, from the most typical green there.
  const border: number[] = [];
  const sample = (x: number, y: number) => {
    const i = (y * width + x) * 4;
    border.push(greenness(pixels[i], pixels[i + 1], pixels[i + 2]));
  };
  const step = Math.max(1, Math.floor(Math.min(width, height) / 128));
  for (let x = 0; x < width; x += step) { sample(x, 0); sample(x, height - 1); }
  for (let y = 0; y < height; y += step) { sample(0, y); sample(width - 1, y); }
  border.sort((a, b) => a - b);
  const key = border[Math.floor(border.length / 2)];
  if (key < 60) throw new CutoutError("The image wasn't drawn on a green screen.");
  // Fully transparent at half the key's greenness and above, opaque below 15% of it.
  const clear = key * 0.5;
  const solid = key * 0.15;
  let minX = width, minY = height, maxX = -1, maxY = -1, opaque = 0;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const i = (y * width + x) * 4;
      const r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
      const d = greenness(r, g, b);
      const alpha = d >= clear ? 0 : d <= solid ? 1 : (clear - d) / (clear - solid);
      // Despill: a subject pixel is never greener than its brightest other channel.
      if (d > 0) pixels[i + 1] = Math.max(r, b);
      pixels[i + 3] = Math.round(alpha * 255);
      if (pixels[i + 3] > 8) {
        opaque += 1;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (opaque < width * height * 0.01) throw new CutoutError("Nothing was left after removing the green screen.");
  const left = Math.max(0, minX - PADDING), top = Math.max(0, minY - PADDING);
  const box = { left, top, width: Math.min(width, maxX + PADDING + 1) - left, height: Math.min(height, maxY + PADDING + 1) - top };
  const { data: png, info: out } = await sharp(Buffer.from(pixels.buffer, pixels.byteOffset, pixels.byteLength), { raw: { width, height, channels: 4 } })
    .extract(box)
    .resize({ width: CUTOUT_MAX_SIDE, height: CUTOUT_MAX_SIDE, fit: "inside", withoutEnlargement: true })
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer({ resolveWithObject: true });
  return { png: new Uint8Array(png), width: out.width, height: out.height };
}
