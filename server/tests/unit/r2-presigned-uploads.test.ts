import { afterEach, describe, expect, it, vi } from "vitest";
import { getObjectStore } from "@/lib/storage/r2";

afterEach(() => vi.unstubAllEnvs());

describe("S3-compatible presigned uploads", () => {
  it("signs the MIME type and size without requiring an empty-body checksum", async () => {
    // Signing is local: these fixture credentials never contact R2.
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("R2_ACCOUNT_ID", "presign-test");
    vi.stubEnv("R2_ACCESS_KEY_ID", "fixture-access");
    vi.stubEnv("R2_SECRET_ACCESS_KEY", "fixture-secret");
    vi.stubEnv("R2_BUCKET", "fixture-bucket");
    const signed = await getObjectStore().signedPut("uploads/test/photo.png", "image/png", 123);
    const url = new URL(signed.url);
    expect(url.hostname).toBe("fixture-bucket.presign-test.r2.cloudflarestorage.com");
    expect(url.searchParams.get("X-Amz-Expires")).toBe("600");
    expect(url.searchParams.get("X-Amz-SignedHeaders")?.split(";")).toEqual(["content-length", "content-type", "host"]);
    expect([...url.searchParams.keys()].filter((key) => /checksum/i.test(key))).toEqual([]);
    expect(signed.headers).toEqual({ "content-type": "image/png" });
    expect(signed.expiresAt.getTime() - Date.now()).toBeGreaterThan(9 * 60 * 1000);
  });
});
