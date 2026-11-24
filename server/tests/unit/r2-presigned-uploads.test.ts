import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getObjectStore, publicObjectUrl } from "@/lib/storage/r2";

afterEach(() => vi.unstubAllEnvs());

describe("S3-compatible presigned uploads", () => {
  beforeEach(() => {
    // Signing is local: these fixture credentials never contact R2.
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("R2_ACCOUNT_ID", "presign-test");
    vi.stubEnv("R2_ACCESS_KEY_ID", "fixture-access");
    vi.stubEnv("R2_SECRET_ACCESS_KEY", "fixture-secret");
    vi.stubEnv("R2_BUCKET", "fixture-bucket");
  });

  it("signs the MIME type and size without requiring an empty-body checksum", async () => {
    const signed = await getObjectStore().signedPut("uploads/test/photo.png", "image/png", 123);
    const url = new URL(signed.url);
    expect(url.hostname).toBe("fixture-bucket.presign-test.r2.cloudflarestorage.com");
    expect(url.searchParams.get("X-Amz-Expires")).toBe("600");
    expect(url.searchParams.get("X-Amz-SignedHeaders")?.split(";")).toEqual(["content-length", "content-type", "host"]);
    expect([...url.searchParams.keys()].filter((key) => /checksum/i.test(key))).toEqual([]);
    expect(signed.headers).toEqual({ "content-type": "image/png" });
    expect(signed.expiresAt.getTime() - Date.now()).toBeGreaterThan(9 * 60 * 1000);
    const download = await getObjectStore().signedGet("document-files/test/會議 Q4.txt", { filename: "會議 Q4.txt" });
    const disposition = new URL(download.url).searchParams.get("response-content-disposition");
    expect(disposition).toBe(`attachment; filename="___Q4.txt"; filename*=UTF-8''${encodeURIComponent("會議 Q4.txt")}`);
  });

  it.each(["chat-uploads", "resume-uploads"])("signs encrypted %s objects in the shared bucket", async namespace => {
    vi.stubEnv("R2_PUBLIC_BASE_URL", "https://cdn.test");
    const store = getObjectStore();
    const path = `${namespace}/owner/document.pdf`;
    const ticket = await store.signedPut(path, "application/pdf", 123);
    const url = new URL(ticket.url);
    const prefix = "x-amz-server-side-encryption-customer-";
    const keyHeader = prefix + "key";
    const key = Buffer.from(ticket.headers[keyHeader], "base64");
    expect(key).toHaveLength(32);
    expect(ticket.headers[prefix + "algorithm"]).toBe("AES256");
    expect(ticket.headers[keyHeader + "-md5"]).toBe(createHash("md5").update(key).digest("base64"));
    expect(url.hostname).toBe("fixture-bucket.presign-test.r2.cloudflarestorage.com");
    expect(url.searchParams.get("X-Amz-SignedHeaders")?.split(";")).toEqual([
      "content-length", "content-type", "host", prefix + "algorithm", keyHeader, keyHeader + "-md5",
    ]);
    expect([...url.searchParams.keys()].some(name => name.toLowerCase().startsWith(prefix))).toBe(false);
    expect(new URLSearchParams(url.search).toString()).not.toContain(encodeURIComponent(ticket.headers[keyHeader]));
    expect((await store.signedPut(path, "application/pdf", 123)).headers[keyHeader]).toBe(ticket.headers[keyHeader]);
    expect((await store.signedPut(path + "2", "application/pdf", 123)).headers[keyHeader]).not.toBe(ticket.headers[keyHeader]);
    expect(publicObjectUrl(path)).toBeNull();
    await expect(store.signedGet(path)).rejects.toMatchObject({ code: "PRIVATE_UPLOAD" });
  });
});
