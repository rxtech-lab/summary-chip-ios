import { randomBytes } from "node:crypto";
import sharp, { type OutputInfo } from "sharp";
import { z } from "zod";
import { siteUrl } from "@/lib/config";
import { createFileUploadSchema } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { fetchPublicDocument } from "@/lib/extract/fetch";
import { ApiError } from "@/lib/http/errors";
import { createUpload, getCompletedUpload } from "@/lib/services/uploads";
import { getObjectStore, publicObjectUrl, type ObjectStore } from "@/lib/storage/r2";
import { miniAccess } from "./service";

/**
 * Files a Clip's users pick on their device (or an agent attaches through MCP). The bytes go to a
 * presigned upload first, then are copied under an unguessable key: images are re-encoded as a
 * JPEG no larger than 2048 px with their metadata (GPS, camera) stripped; other files are kept as
 * they are and only ever served as downloads. The returned file reference is plain JSON the app
 * keeps in state or in a record's json field.
 */

export const MINI_FILE_MAX_BYTES = 25 * 1024 * 1024;
const MAX_EDGE = 2048;
export const MINI_FILE_CACHE_CONTROL = "public, max-age=31536000, immutable";
const PREFIX = "mini-app-files/";
const FILE_PATTERN = /^[0-9a-f]{32}\/[A-Za-z0-9._-]{1,120}$/;

export const attachMiniFileSchema = z.object({
  /** The key from the Clip's upload (or MCP create_upload), after PUT completes. */
  uploadKey: z.string().trim().min(1).max(300).nullish(),
  /** A public file URL to copy (MCP only). */
  url: z.string().trim().url().max(4096).nullish(),
  /** The name shown for the file; defaults to the upload's file name. */
  name: z.string().trim().min(1).max(200).nullish(),
}).refine(input => [input.uploadKey, input.url].filter(Boolean).length === 1, "give exactly one of uploadKey or url");
export type AttachMiniFileInput = z.infer<typeof attachMiniFileSchema>;

export interface MiniAppFile {
  [key: string]: string | number;
  id: string;
  url: string;
  name: string;
  contentType: string;
  size: number;
}

function safeName(name: string): string {
  const cleaned = name.normalize("NFKD").replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^[._]+/, "").slice(0, 120);
  return cleaned || "file";
}

/** The R2 key of `/api/public/mini-app-files/:token/:name`, or null for anything else. */
export function miniFileKeyFor(token: string, name: string): string | null {
  const file = `${token}/${name}`;
  return FILE_PATTERN.test(file) ? PREFIX + file : null;
}

/** Images may come from the bucket's custom domain; other files always go through the app, as downloads. */
export function miniFileUrl(key: string, image: boolean): string {
  const path = key.slice(PREFIX.length).split("/").map(encodeURIComponent).join("/");
  return (image ? publicObjectUrl(key) : null) ?? `${siteUrl()}/api/public/mini-app-files/${path}`;
}

function isImage(contentType: string): boolean {
  return contentType.startsWith("image/") && contentType !== "image/svg+xml";
}

/** A presigned upload for a file the user picked in a Clip they can open. */
export async function createMiniAppUpload(db: Database, appId: string, userId: string, input: unknown, store: ObjectStore = getObjectStore()) {
  await miniAccess(db, appId, userId);
  return createUpload(db, userId, createFileUploadSchema.parse(input), store);
}

/** Copies an uploaded (or, for agents, public) file into the Clip's storage and returns its reference. */
export async function attachMiniAppFile(db: Database, appId: string, userId: string, input: AttachMiniFileInput, deps: { store?: ObjectStore } = {}): Promise<MiniAppFile> {
  await miniAccess(db, appId, userId);
  const store = deps.store ?? getObjectStore();
  let bytes: Uint8Array; let contentType: string; let name: string;
  if (input.uploadKey) {
    const { upload, mimeType } = await getCompletedUpload(db, userId, input.uploadKey, store, MINI_FILE_MAX_BYTES);
    bytes = (await store.get(input.uploadKey)).bytes;
    contentType = mimeType; name = input.name ?? upload.filename;
  } else {
    const fetched = await fetchPublicDocument(input.url!, { maxBytes: MINI_FILE_MAX_BYTES, timeoutMs: 20_000 });
    bytes = fetched.bytes; contentType = fetched.contentType || "application/octet-stream";
    name = input.name ?? decodeURIComponent(new URL(input.url!).pathname.split("/").pop() || "file");
  }
  if (bytes.byteLength > MINI_FILE_MAX_BYTES) throw new ApiError(413, "UPLOAD_TOO_LARGE", "The file is larger than 25 MB");
  const token = randomBytes(16).toString("hex");
  if (isImage(contentType)) {
    let encoded: { data: Buffer; info: OutputInfo };
    try {
      encoded = await sharp(bytes, { limitInputPixels: 8192 * 8192, failOn: "error" })
        .rotate()
        .resize({ width: MAX_EDGE, height: MAX_EDGE, fit: "inside", withoutEnlargement: true })
        .flatten({ background: "#ffffff" })
        .jpeg({ quality: 82, mozjpeg: true })
        .toBuffer({ resolveWithObject: true });
    } catch {
      throw new ApiError(422, "IMAGE_INVALID", "The image could not be read. Use a JPEG, PNG, WebP, GIF or AVIF image.");
    }
    const stored = safeName(name.replace(/\.[A-Za-z0-9]{1,8}$/, "")).slice(0, 115) + ".jpg";
    const key = `${PREFIX}${token}/${stored}`;
    await store.put(key, { bytes: new Uint8Array(encoded.data), contentType: "image/jpeg", cacheControl: MINI_FILE_CACHE_CONTROL });
    return { id: token, url: miniFileUrl(key, true), name, contentType: "image/jpeg", size: encoded.info.size, width: encoded.info.width, height: encoded.info.height };
  }
  const key = `${PREFIX}${token}/${safeName(name)}`;
  await store.put(key, { bytes, contentType, cacheControl: MINI_FILE_CACHE_CONTROL });
  return { id: token, url: miniFileUrl(key, false), name, contentType, size: bytes.byteLength };
}
