import { createHash, randomBytes } from "node:crypto";
import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { r2PublicBaseUrl } from "@/lib/config";
import { ApiError } from "@/lib/http/errors";

export interface StoredObject {
  bytes: Uint8Array;
  contentType: string;
  /** Sent as `Cache-Control` by R2's custom domain. */
  cacheControl?: string;
}

export interface ObjectStore {
  signedPut(key: string, contentType: string, byteSize: number): Promise<{ url: string; expiresAt: Date; headers: Record<string, string> }>;
  signedGet(key: string, options?: { filename?: string; expiresInSeconds?: number; inline?: boolean }): Promise<{ url: string; expiresAt: Date }>;
  put(key: string, object: StoredObject): Promise<void>;
  get(key: string): Promise<StoredObject>;
  head(key: string): Promise<{ contentType?: string; byteSize?: number } | null>;
  delete(key: string): Promise<void>;
}

const UPLOAD_URL_TTL_SECONDS = 600;

function isMissing(error: unknown): boolean {
  const name = (error as { name?: string } | undefined)?.name;
  const status = (error as { $metadata?: { httpStatusCode?: number } } | undefined)?.$metadata?.httpStatusCode;
  return name === "NoSuchKey" || name === "NotFound" || status === 404;
}

function safeFilename(filename: string | undefined): string {
  return filename?.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 120) || "document.pdf";
}

class R2ObjectStore implements ObjectStore {
  private readonly client: S3Client;
  private readonly bucket: string;

  constructor() {
    const accountId = process.env.R2_ACCOUNT_ID;
    const accessKeyId = process.env.R2_ACCESS_KEY_ID;
    const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
    const bucket = process.env.R2_BUCKET;
    if (!accountId || !accessKeyId || !secretAccessKey || !bucket) {
      throw new ApiError(503, "STORAGE_NOT_CONFIGURED", "Cloudflare R2 is not configured");
    }
    this.bucket = bucket;
    this.client = new S3Client({
      region: "auto",
      endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
      credentials: { accessKeyId, secretAccessKey },
      // A presigned PUT has no body yet: do not sign a checksum of an empty payload.
      requestChecksumCalculation: "WHEN_REQUIRED",
    });
  }

  async signedPut(key: string, contentType: string, byteSize: number) {
    const command = new PutObjectCommand({ Bucket: this.bucket, Key: key, ContentType: contentType, ContentLength: byteSize });
    return {
      url: await getSignedUrl(this.client, command, {
        expiresIn: UPLOAD_URL_TTL_SECONDS,
        signableHeaders: new Set(["content-type"]),
      }),
      expiresAt: new Date(Date.now() + UPLOAD_URL_TTL_SECONDS * 1000),
      headers: { "content-type": contentType },
    };
  }

  async signedGet(key: string, options: { filename?: string; expiresInSeconds?: number; inline?: boolean } = {}) {
    const expiresIn = options.expiresInSeconds ?? 300;
    const disposition = options.filename
      ? `${options.inline ? "inline" : "attachment"}; filename="${safeFilename(options.filename)}"`
      : undefined;
    const command = new GetObjectCommand({
      Bucket: this.bucket,
      Key: key,
      ...(disposition ? { ResponseContentDisposition: disposition } : {}),
    });
    return { url: await getSignedUrl(this.client, command, { expiresIn }), expiresAt: new Date(Date.now() + expiresIn * 1000) };
  }

  async put(key: string, object: StoredObject): Promise<void> {
    await this.client.send(new PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      Body: object.bytes,
      ContentType: object.contentType,
      ...(object.cacheControl ? { CacheControl: object.cacheControl } : {}),
    }));
  }

  async get(key: string): Promise<StoredObject> {
    try {
      const result = await this.client.send(new GetObjectCommand({ Bucket: this.bucket, Key: key }));
      if (!result.Body) throw new ApiError(404, "OBJECT_MISSING", "The stored object does not exist");
      return { bytes: await result.Body.transformToByteArray(), contentType: result.ContentType ?? "application/octet-stream" };
    } catch (error) {
      if (isMissing(error)) throw new ApiError(404, "OBJECT_MISSING", "The stored object does not exist");
      throw error;
    }
  }

  async head(key: string) {
    try {
      const result = await this.client.send(new HeadObjectCommand({ Bucket: this.bucket, Key: key }));
      return { contentType: result.ContentType, byteSize: result.ContentLength };
    } catch (error) {
      if (isMissing(error)) return null;
      throw error;
    }
  }

  async delete(key: string): Promise<void> {
    await this.client.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: key }));
  }
}

/** In-process store for tests and `SUMMARY_MOCK_SERVICES=true` local development. */
export class MemoryObjectStore implements ObjectStore {
  readonly objects = new Map<string, StoredObject>();

  async signedPut(key: string, contentType: string, byteSize: number) {
    return {
      url: `https://uploads.invalid/${encodeURIComponent(key)}?size=${byteSize}`,
      expiresAt: new Date(Date.now() + UPLOAD_URL_TTL_SECONDS * 1000),
      headers: { "content-type": contentType },
    };
  }
  async signedGet(key: string, options: { filename?: string; expiresInSeconds?: number } = {}) {
    if (!this.objects.has(key)) throw new ApiError(404, "OBJECT_MISSING", "The stored object does not exist");
    return {
      url: `https://downloads.invalid/${encodeURIComponent(key)}`,
      expiresAt: new Date(Date.now() + (options.expiresInSeconds ?? 300) * 1000),
    };
  }
  async put(key: string, object: StoredObject) { this.objects.set(key, object); }
  async get(key: string) {
    const object = this.objects.get(key);
    if (!object) throw new ApiError(404, "OBJECT_MISSING", "The stored object does not exist");
    return object;
  }
  async head(key: string) {
    const object = this.objects.get(key);
    return object ? { contentType: object.contentType, byteSize: object.bytes.byteLength } : null;
  }
  async delete(key: string) { this.objects.delete(key); }
}

export function mockServicesEnabled(): boolean {
  return process.env.NODE_ENV === "test"
    || (process.env.NODE_ENV !== "production" && process.env.SUMMARY_MOCK_SERVICES === "true");
}

let testStore: ObjectStore | undefined;
let r2Store: ObjectStore | undefined;

export function setObjectStoreForTests(store?: ObjectStore): void {
  testStore = store;
}

export function getObjectStore(): ObjectStore {
  if (testStore) return testStore;
  if (mockServicesEnabled()) {
    testStore = new MemoryObjectStore();
    return testStore;
  }
  r2Store ??= new R2ObjectStore();
  return r2Store;
}

/** Owner-scoped prefix for uploads; hashing keeps the RxAuth subject out of object keys. */
export function ownerKeyPrefix(ownerId: string): string {
  return createHash("sha256").update(ownerId).digest("hex").slice(0, 24);
}

export function uploadKey(ownerId: string, uploadId: string, mimeType = "application/pdf"): string {
  const extension = ({
    "application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
    "image/gif": "gif", "image/avif": "avif", "image/heic": "heic", "text/plain": "txt",
  } as Record<string, string>)[mimeType] ?? "bin";
  return `uploads/${ownerKeyPrefix(ownerId)}/${uploadId}.${extension}`;
}

const UPLOAD_KEY_PATTERN = /^uploads\/([0-9a-f]{24})\/([0-9a-f-]{36})\.(?:pdf|jpg|png|webp|gif|avif|heic|txt|bin)$/;

export function isOwnedUploadKey(ownerId: string, key: string): boolean {
  const match = UPLOAD_KEY_PATTERN.exec(key);
  return Boolean(match && match[1] === ownerKeyPrefix(ownerId));
}

/**
 * OG image keys carry a random suffix: with a public custom domain the key *is* the capability, so
 * it must not be derivable, and rotating it (see `patchSummary`) revokes the old public URL.
 */
export function ogImageKey(summaryId: string, timestamp = Date.now()): string {
  return `og/${summaryId}-${timestamp}-${randomBytes(6).toString("hex")}.png`;
}

/** Key of the text-free artwork that goes with an OG image (same capability rules as `ogImageKey`). */
export function artImageKey(summaryId: string, timestamp = Date.now()): string {
  return `art/${summaryId}-${timestamp}-${randomBytes(6).toString("hex")}.png`;
}

/** Short so that rotating the key on "make private" takes effect at the CDN within minutes. */
export const OG_CACHE_CONTROL = "public, max-age=300";

/** URL of an object on the bucket's public custom domain, or null when `R2_PUBLIC_BASE_URL` is unset. */
export function publicObjectUrl(key: string): string | null {
  const base = r2PublicBaseUrl();
  return base ? `${base}/${key.split("/").map(encodeURIComponent).join("/")}` : null;
}
