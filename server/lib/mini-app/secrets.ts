import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { ApiError } from "@/lib/http/errors";
export function fingerprint(value: unknown): string { return createHash("sha256").update(JSON.stringify(value) ?? "null").digest("hex"); }
function keyring() {
  try {
    const keys = JSON.parse(process.env.MINI_APP_SECRET_KEYS ?? "{}");
    const active = process.env.MINI_APP_ACTIVE_SECRET_KEY ?? "";
    if (!active || typeof keys[active] !== "string" || Buffer.from(keys[active], "base64").length !== 32) throw new Error();
    return { keys: keys as Record<string, string>, active };
  } catch { throw new ApiError(503, "MINI_SECRETS_NOT_CONFIGURED", "Connection encryption is not configured"); }
}
export function seal(value: unknown, binding: string): string {
  const { keys, active } = keyring(); const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", Buffer.from(keys[active], "base64"), iv);
  cipher.setAAD(Buffer.from(binding));
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
  return JSON.stringify({ v: 1, key: active, iv: iv.toString("base64"), tag: cipher.getAuthTag().toString("base64"), data: ciphertext.toString("base64") });
}
export function unseal<T>(encrypted: string, binding: string): T {
  const { keys } = keyring();
  try {
    const payload = JSON.parse(encrypted);
    if (payload.v !== 1 || !keys[payload.key]) throw new Error();
    const decipher = createDecipheriv("aes-256-gcm", Buffer.from(keys[payload.key], "base64"), Buffer.from(payload.iv, "base64"));
    decipher.setAAD(Buffer.from(binding)); decipher.setAuthTag(Buffer.from(payload.tag, "base64"));
    return JSON.parse(Buffer.concat([decipher.update(Buffer.from(payload.data, "base64")), decipher.final()]).toString());
  } catch { throw new ApiError(503, "MINI_SECRET_UNAVAILABLE", "Reconnect this account to continue"); }
}
