import { randomBytes } from "node:crypto";
import { compressDocumentImage } from "../../packages/rich-document-media";
import type { Database } from "@/lib/db/client";
import { siteUrl } from "@/lib/config";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, publicObjectUrl } from "@/lib/storage/r2";
import { getCompletedUpload } from "./uploads";

/** Only JSON metadata reaches the API. Image bytes come directly from the signed S3 upload. */
export async function finishDocumentImageUpload(db: Database, ownerId: string, uploadKey: string) {
  const store = getObjectStore();
  const { mimeType } = await getCompletedUpload(db, ownerId, uploadKey, store, 15 * 1024 * 1024);
  if (!mimeType.startsWith("image/")) throw new ApiError(422, "IMAGE_INVALID", "Upload an image");
  const original = await store.get(uploadKey);
  if (original.bytes.byteLength > 15 * 1024 * 1024) throw new ApiError(413, "IMAGE_TOO_LARGE", "Images must be 15 MB or smaller");
  let encoded;
  try { encoded = await compressDocumentImage(original.bytes); }
  catch { throw new ApiError(422, "IMAGE_INVALID", "The image could not be decoded"); }
  const file = `${randomBytes(24).toString("hex")}.webp`;
  const key = `document-images/${file}`;
  await store.put(key, { bytes: encoded.data, contentType: "image/webp", cacheControl: "public, max-age=31536000, immutable" });
  return { url: publicObjectUrl(key) ?? `${siteUrl()}/api/public/document-images/${file}`, byteSize: encoded.info.size, width: encoded.info.width, height: encoded.info.height };
}
