import { randomBytes } from "node:crypto";

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/** 10-character URL-safe slug (62^10 ≈ 8e17), drawn without modulo bias. */
export function generateSlug(length = 10): string {
  let out = "";
  while (out.length < length) {
    for (const byte of randomBytes(length * 2)) {
      if (byte < 248) out += ALPHABET[byte % 62];
      if (out.length === length) break;
    }
  }
  return out;
}

export function isValidSlug(value: string): boolean {
  return /^[A-Za-z0-9]{6,32}$/.test(value);
}
