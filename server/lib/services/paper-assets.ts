import { createHash } from "node:crypto";
import { and, eq, inArray, sql } from "drizzle-orm";
import { MAX_PAPER_ASSET_BYTES, type PaperDocument, type PaperFile } from "@/lib/contracts/paper";
import type { Database } from "@/lib/db/client";
import { uploads } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import type { ObjectStore } from "@/lib/storage/r2";
import { getCompletedUpload } from "./uploads";

function assetPrefix(paperId: string): string { return `papers/${paperId}/assets/`; }

export function isPaperAssetKey(paperId: string, key: string): boolean {
  return key.startsWith(assetPrefix(paperId)) && /^[0-9a-f]{64}-[0-9a-f-]{36}\.(?:png|jpg|pdf)$/.test(key.slice(assetPrefix(paperId).length));
}

function matchesImage(bytes: Uint8Array, mimeType: string): boolean {
  const buffer = Buffer.from(bytes);
  if (mimeType === "image/png") return buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  if (mimeType === "application/pdf") return buffer.subarray(0, 5).toString("ascii") === "%PDF-";
  return mimeType === "image/jpeg" && buffer[0] === 255 && buffer[1] === 216 && buffer[2] === 255;
}

/** Copies a completed, owner-scoped upload into immutable paper storage. A presigned PUT can
 * still overwrite the staging key, so versions must reference the content-addressed copy. */
export async function preparePaperAssets(db: Database, store: ObjectStore, ownerId: string, paperId: string, document: PaperDocument, knownFiles: PaperFile[] = []): Promise<PaperDocument> {
  const files: PaperFile[] = [];
  for (const file of document.files) {
    const asset = file.asset;
    if (!asset) { files.push(file); continue; }
    if (isPaperAssetKey(paperId, asset.key)) {
      // Typing does not revalidate every unchanged image over S3 on each autosave. Only trusted
      // references already in this paper's database row qualify; new references are checked.
      if (knownFiles.some((known) => known.asset?.key === asset.key && known.asset.byteSize === asset.byteSize && known.asset.mimeType === asset.mimeType)) {
        files.push(file);
        continue;
      }
      const [row] = await db.select().from(uploads).where(and(eq(uploads.key, asset.key), eq(uploads.ownerId, ownerId), eq(uploads.summaryId, paperId))).limit(1);
      const head = row ? await store.head(asset.key) : null;
      if (!head) throw new ApiError(422, "PAPER_ASSET_MISSING", `The image ${file.path} is missing; upload it again`);
      if (head.byteSize !== asset.byteSize || head.contentType !== asset.mimeType) throw new ApiError(422, "PAPER_ASSET_INVALID", `The image metadata for ${file.path} does not match storage`);
      files.push(file);
      continue;
    }
    const completed = await getCompletedUpload(db, ownerId, asset.key, store, MAX_PAPER_ASSET_BYTES);
    if (completed.upload.byteSize !== asset.byteSize || completed.mimeType !== asset.mimeType) {
      throw new ApiError(422, "PAPER_ASSET_INVALID", `The upload metadata for ${file.path} does not match storage`);
    }
    const object = await store.get(asset.key);
    if (object.bytes.byteLength !== asset.byteSize || object.contentType !== asset.mimeType || !matchesImage(object.bytes, asset.mimeType)) {
      throw new ApiError(422, "PAPER_ASSET_INVALID", `The uploaded bytes for ${file.path} are not a valid ${asset.mimeType} asset`);
    }
    const hash = createHash("sha256").update(object.bytes).digest("hex");
    const ext = asset.mimeType === "image/png" ? "png" : asset.mimeType === "image/jpeg" ? "jpg" : "pdf";
    // Keep the upload's random id as a capability: a public bucket domain must not expose a
    // private image at a key derivable from the paper id and known image bytes alone.
    const uploadId = completed.upload.key.split("/").at(-1)!.split(".")[0];
    const key = `${assetPrefix(paperId)}${hash}-${uploadId}.${ext}`;
    // Only server writes reach this namespace; staging upload tickets never target it.
    await store.put(key, { ...object, cacheControl: "private, max-age=0" });
    await db.insert(uploads).values({ key, ownerId, filename: file.path, byteSize: asset.byteSize, summaryId: paperId, createdAt: new Date() }).onConflictDoNothing();
    files.push({ ...file, asset: { ...asset, key } });
  }
  return { ...document, files };
}

/** Protects images referenced by the working copy or any saved version from orphan cleanup. */
export function paperAssetStatements(db: Database, paperId: string, document: PaperDocument, at: Date, fenced = false) {
  const keys = document.files.flatMap((file) => file.asset ? [file.asset.key] : []);
  return keys.length ? [db.update(uploads).set({ attachedAt: at }).where(and(
    eq(uploads.summaryId, paperId), inArray(uploads.key, keys), ...(fenced ? [sql`changes() > 0`] : []),
  ))] : [];
}

export async function paperAssetBytes(store: ObjectStore, paperId: string, file: PaperFile) {
  const asset = file.asset;
  if (!asset || !isPaperAssetKey(paperId, asset.key)) throw new ApiError(422, "PAPER_ASSET_INVALID", `The image reference for ${file.path} is invalid`);
  const head = await store.head(asset.key);
  if (!head) throw new ApiError(422, "PAPER_ASSET_MISSING", `The image ${file.path} is missing`);
  if (head.byteSize !== asset.byteSize || head.byteSize > MAX_PAPER_ASSET_BYTES) throw new ApiError(422, "PAPER_ASSET_INVALID", `The image size for ${file.path} is invalid`);
  const object = await store.get(asset.key);
  if (object.bytes.byteLength !== asset.byteSize || object.contentType !== asset.mimeType) throw new ApiError(422, "PAPER_ASSET_INVALID", `The image metadata for ${file.path} is invalid`);
  return object;
}
