import type { z } from "zod";
import type { createUploadSchema } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { uploads } from "@/lib/db/schema";
import { getObjectStore, uploadKey, type ObjectStore } from "@/lib/storage/r2";

export async function createUpload(
  db: Database,
  ownerId: string,
  input: z.infer<typeof createUploadSchema>,
  store: ObjectStore = getObjectStore(),
) {
  const key = uploadKey(ownerId, crypto.randomUUID());
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
