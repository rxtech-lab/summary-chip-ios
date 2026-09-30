import sharp from "sharp";

export const OG_IMAGE_WIDTH = 1200;
export const OG_IMAGE_HEIGHT = 630;

/**
 * Fits a generated OG image to 1200×630. Image models only offer a few aspect ratios (16:9, 3:2),
 * so the drawing is cover-cropped around its centre; the prompt keeps text away from the edges.
 */
export async function fitGeneratedOg(bytes: Uint8Array): Promise<Uint8Array> {
  const output = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .resize(OG_IMAGE_WIDTH, OG_IMAGE_HEIGHT, { fit: "cover", position: "centre" })
    .png({ compressionLevel: 9, palette: false })
    .toBuffer();
  return new Uint8Array(output);
}
