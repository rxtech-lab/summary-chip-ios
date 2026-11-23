import { randomBytes } from "node:crypto";
import type { Database } from "@/lib/db/client";
import { siteUrl } from "@/lib/config";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { storeDocumentImage } from "./document-images";
import { getCompletedUpload } from "./uploads";

/**
 * Attachments for documents such as todo items. Images reuse the WebP image policy; any other file is
 * copied as-is under an unguessable token and served as an attachment directly from storage.
 */
export const DOCUMENT_FILE_MAX_BYTES = 25 * 1024 * 1024;
const PREFIX = "document-files/";
const TOKEN_PATTERN = /^[0-9a-f]{32}$/;

export interface DocumentFile { id: string; url: string; name: string; contentType: string; size: number }

function safeName(name: string): string {
  const cleaned = name.normalize("NFC").replace(/[^\p{L}\p{M}\p{N} ._-]+/gu, "_").replace(/^[ ._]+/, "").slice(0, 200).trim();
  return cleaned || "file";
}

/** The R2 key behind `/api/public/document-files/:token/:name`, or null for anything else. */
export function documentFileKeyFor(token: string, name: string): string | null {
  if (!TOKEN_PATTERN.test(token) || name !== safeName(name)) return null;
  return `${PREFIX}${token}/${name}`;
}

function isRasterImage(contentType: string) {
  return contentType.startsWith("image/") && contentType !== "image/svg+xml";
}

export async function finishDocumentFileUpload(
  db: Database, ownerId: string, uploadKey: string, name?: string | null, store: ObjectStore = getObjectStore(),
): Promise<DocumentFile> {
  const { upload, mimeType } = await getCompletedUpload(db, ownerId, uploadKey, store, DOCUMENT_FILE_MAX_BYTES);
  const displayName = (name ?? upload.filename).trim().slice(0, 200) || "file";
  const token = randomBytes(16).toString("hex");
  const { bytes } = await store.get(uploadKey);
  if (bytes.byteLength > DOCUMENT_FILE_MAX_BYTES) throw new ApiError(413, "UPLOAD_TOO_LARGE", "The file is larger than 25 MB");
  if (isRasterImage(mimeType)) {
    try {
      const image = await storeDocumentImage(bytes, store);
      return { id: token, url: image.url, name: displayName, contentType: "image/webp", size: image.byteSize };
    } catch (error) {
      // A photo in a format this Sharp build cannot decode can still be attached as a file.
      if (!(error instanceof ApiError) || error.code !== "IMAGE_INVALID") throw error;
    }
  }
  const stored = safeName(displayName);
  const key = `${PREFIX}${token}/${stored}`;
  await store.put(key, { bytes, contentType: "application/octet-stream" });
  return {
    id: token, url: `${siteUrl()}/api/public/document-files/${token}/${encodeURIComponent(stored)}`, name: displayName,
    contentType: mimeType.startsWith("image/") ? "application/octet-stream" : mimeType, size: bytes.byteLength,
  };
}
