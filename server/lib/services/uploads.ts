import { and, eq } from "drizzle-orm";
import type { z } from "zod";
import { createFileUploadSchema, MAX_UPLOAD_BYTES } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { uploads } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, isOwnedUploadKey, uploadKey, type ObjectStore } from "@/lib/storage/r2";

export async function createUpload(
  db: Database,
  ownerId: string,
  input: z.infer<typeof createFileUploadSchema>,
  store: ObjectStore = getObjectStore(),
) {
  input = createFileUploadSchema.parse(input);
  const key = uploadKey(ownerId, crypto.randomUUID(), input.mimeType);
  const signed = await store.signedPut(key, input.mimeType, input.byteSize);
  await db.insert(uploads).values({
    key,
    ownerId,
    filename: input.filename.slice(0, 300),
    byteSize: input.byteSize,
    createdAt: new Date(),
  });
  return {
    key,
    uploadUrl: signed.url,
    method: "PUT" as const,
    headers: signed.headers,
    expiresAt: signed.expiresAt.toISOString(),
  };
}

/** Checks ownership and completion before granting access to an uploaded file. */
export async function getCompletedUpload(
  db: Database,
  ownerId: string,
  key: string,
  store: ObjectStore = getObjectStore(),
  maxBytes = MAX_UPLOAD_BYTES,
) {
  if (!isOwnedUploadKey(ownerId, key)) {
    throw new ApiError(403, "UPLOAD_FORBIDDEN", "This upload does not belong to you");
  }
  const [upload] = await db.select().from(uploads)
    .where(and(eq(uploads.key, key), eq(uploads.ownerId, ownerId))).limit(1);
  if (!upload) throw new ApiError(404, "UPLOAD_NOT_FOUND", "The upload does not exist or has expired");
  if (upload.byteSize > maxBytes) throw new ApiError(413, "UPLOAD_TOO_LARGE", `The file is larger than ${maxBytes / (1024 * 1024)} MB`);
  const head = await store.head(key);
  if (!head) throw new ApiError(409, "UPLOAD_INCOMPLETE", "The file has not finished uploading");
  if ((head.byteSize ?? 0) > maxBytes) throw new ApiError(413, "UPLOAD_TOO_LARGE", `The file is larger than ${maxBytes / (1024 * 1024)} MB`);
  if (head.byteSize !== upload.byteSize) throw new ApiError(409, "UPLOAD_SIZE_MISMATCH", "The uploaded file size does not match byteSize");
  return { upload, mimeType: head.contentType ?? "application/octet-stream" };
}

/** A short-lived download URL; raw uploads are never given a public CDN URL. */
export async function getUpload(
  db: Database,
  ownerId: string,
  key: string,
  store: ObjectStore = getObjectStore(),
) {
  const { upload, mimeType } = await getCompletedUpload(db, ownerId, key, store);
  const signed = await store.signedGet(key, { filename: upload.filename });
  return {
    key, filename: upload.filename, mimeType, byteSize: upload.byteSize,
    downloadUrl: signed.url, expiresAt: signed.expiresAt.toISOString(),
  };
}
