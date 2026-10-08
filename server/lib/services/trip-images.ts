import { randomBytes } from "node:crypto";
import sharp, { type OutputInfo } from "sharp";
import { z } from "zod";
import { siteUrl } from "@/lib/config";
import type { Database } from "@/lib/db/client";
import { fetchPublicDocument } from "@/lib/extract/fetch";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, publicObjectUrl, type ObjectStore } from "@/lib/storage/r2";
import { getOwnedTrip } from "./trips";
import { getCompletedUpload } from "./uploads";

/**
 * Photos agents upload for a trip's places and views. Each one is fetched (from a public URL, SSRF
 * checked), decoded (base64) or read from an owned upload, re-encoded as a JPEG no larger than 2048 px with its metadata
 * (GPS, camera) stripped, and stored in R2 under an unguessable key. The returned https URL goes
 * into a place's `photos` or an `Image`/`Gallery` view, and keeps working when the original page
 * moves or blocks hotlinking.
 */

/** Largest image accepted before re-encoding. */
export const TRIP_IMAGE_MAX_BYTES = 15 * 1024 * 1024;
const MAX_EDGE = 2048;
export const TRIP_IMAGE_CACHE_CONTROL = "public, max-age=31536000, immutable";

export const uploadTripImageSchema = z.object({
  /** A public image URL to copy. */
  url: z.string().trim().url().max(4096).nullish(),
  /** The image itself, base64 (a `data:` URL works too). */
  data: z.string().trim().max(Math.ceil((TRIP_IMAGE_MAX_BYTES * 4) / 3) + 100).nullish(),
  /** The key from create_upload, after PUT completes. */
  uploadKey: z.string().trim().min(1).max(300).nullish(),
}).refine((input) => [input.url, input.data, input.uploadKey].filter(Boolean).length === 1, "give exactly one of url, data or uploadKey");
export type UploadTripImageInput = z.infer<typeof uploadTripImageSchema>;

export interface UploadedTripImage {
  url: string;
  width: number;
  height: number;
  byteSize: number;
}

const FILE_PATTERN = /^[A-Za-z0-9_-]{1,100}-\d{10,16}-[0-9a-f]{16}\.jpg$/;

export function tripImageKey(tripId: string, timestamp = Date.now()): string {
  return `trip-images/${tripId.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 100)}-${timestamp}-${randomBytes(8).toString("hex")}.jpg`;
}

/** The R2 key of `/api/public/trip-images/:file`, or null for anything that isn't a trip image's file name. */
export function tripImageKeyForFile(file: string): string | null {
  return FILE_PATTERN.test(file) ? `trip-images/${file}` : null;
}

/** Served from the bucket's custom domain when there is one, else through the app. */
export function tripImageUrl(key: string): string {
  return publicObjectUrl(key) ?? `${siteUrl()}/api/public/trip-images/${encodeURIComponent(key.slice("trip-images/".length))}`;
}

function invalidImage(message = "The image could not be read. Use a JPEG, PNG, WebP, GIF, AVIF or HEIC image."): ApiError {
  return new ApiError(422, "IMAGE_INVALID", message);
}

async function sourceBytes(input: UploadTripImageInput): Promise<Uint8Array> {
  if (input.url) {
    const fetched = await fetchPublicDocument(input.url, { maxBytes: TRIP_IMAGE_MAX_BYTES, timeoutMs: 20_000, accept: "image/*" });
    if (!fetched.contentType.startsWith("image/") && fetched.contentType !== "application/octet-stream") {
      throw invalidImage(`The URL is not an image (${fetched.contentType || "unknown type"}).`);
    }
    return fetched.bytes;
  }
  const base64 = (input.data ?? "").replace(/^data:[^;,]*;base64,/, "").replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/_-]+=*$/.test(base64)) throw invalidImage("data must be base64.");
  const bytes = new Uint8Array(Buffer.from(base64, "base64"));
  if (bytes.length > TRIP_IMAGE_MAX_BYTES) throw new ApiError(413, "IMAGE_TOO_LARGE", "The image is larger than 15 MB.");
  return bytes;
}

/** Copies, decodes or consumes an uploaded image for an owned trip and returns its stored URL. */
export async function uploadTripImage(
  db: Database,
  ownerId: string,
  tripId: string,
  input: UploadTripImageInput,
  deps: { store?: ObjectStore; now?: () => Date } = {},
): Promise<UploadedTripImage> {
  const { summary } = await getOwnedTrip(db, tripId, ownerId);
  const store = deps.store ?? getObjectStore();
  let bytes: Uint8Array;
  if (input.uploadKey) {
    const { mimeType } = await getCompletedUpload(db, ownerId, input.uploadKey, store, TRIP_IMAGE_MAX_BYTES);
    if (!mimeType.startsWith("image/") && mimeType !== "application/octet-stream") throw invalidImage("The uploaded file is not an image.");
    bytes = (await store.get(input.uploadKey)).bytes;
    if (bytes.byteLength > TRIP_IMAGE_MAX_BYTES) throw new ApiError(413, "IMAGE_TOO_LARGE", "The image is larger than 15 MB.");
  } else {
    bytes = await sourceBytes(input);
  }
  let encoded: { data: Buffer; info: OutputInfo };
  try {
    encoded = await sharp(bytes, { limitInputPixels: 8192 * 8192, failOn: "error" })
      .rotate()
      .resize({ width: MAX_EDGE, height: MAX_EDGE, fit: "inside", withoutEnlargement: true })
      .flatten({ background: "#ffffff" })
      .jpeg({ quality: 82, mozjpeg: true })
      .toBuffer({ resolveWithObject: true });
  } catch {
    throw invalidImage();
  }
  const key = tripImageKey(summary.id, (deps.now?.() ?? new Date()).getTime());
  await store.put(key, { bytes: new Uint8Array(encoded.data), contentType: "image/jpeg", cacheControl: TRIP_IMAGE_CACHE_CONTROL });
  return { url: tripImageUrl(key), width: encoded.info.width, height: encoded.info.height, byteSize: encoded.info.size };
}
