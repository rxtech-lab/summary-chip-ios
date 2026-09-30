import { ApiError } from "@/lib/http/errors";
import { assertPublicUrl } from "./ssrf";

export const BROWSER_USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

export interface FetchedDocument {
  url: URL;
  contentType: string;
  charset?: string;
  bytes: Uint8Array;
}

const MAX_REDIRECTS = 5;

async function readCapped(response: Response, maxBytes: number): Promise<Uint8Array> {
  const declared = Number(response.headers.get("content-length") ?? 0);
  if (declared > maxBytes) throw new ApiError(422, "SOURCE_TOO_LARGE", "The page is too large to summarise");
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) throw new ApiError(422, "SOURCE_TOO_LARGE", "The page is too large to summarise");
      chunks.push(value);
    }
  } finally {
    reader.cancel().catch(() => undefined);
  }
  const out = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

/** Fetches a public URL with a browser-like UA, a timeout, a byte cap and SSRF checks on every hop. */
export async function fetchPublicDocument(
  rawUrl: string,
  options: { maxBytes?: number; timeoutMs?: number; accept?: string } = {},
): Promise<FetchedDocument> {
  const maxBytes = options.maxBytes ?? 5 * 1024 * 1024;
  const signal = AbortSignal.timeout(options.timeoutMs ?? 15_000);
  let url = await assertPublicUrl(rawUrl);
  for (let hop = 0; hop <= MAX_REDIRECTS; hop += 1) {
    let response: Response;
    try {
      response = await fetch(url, {
        redirect: "manual",
        signal,
        headers: {
          "user-agent": BROWSER_USER_AGENT,
          accept: options.accept ?? "text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8,*/*;q=0.5",
          "accept-language": "en-US,en;q=0.9,*;q=0.5",
        },
      });
    } catch (error) {
      if (error instanceof ApiError) throw error;
      const timedOut = (error as { name?: string }).name === "TimeoutError" || (error as { name?: string }).name === "AbortError";
      throw new ApiError(422, timedOut ? "SOURCE_TIMEOUT" : "SOURCE_UNREACHABLE", timedOut ? "The page took too long to respond" : "The page could not be fetched");
    }
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      response.body?.cancel().catch(() => undefined);
      if (!location) throw new ApiError(422, "SOURCE_UNREACHABLE", "The page redirected without a location");
      url = await assertPublicUrl(new URL(location, url));
      continue;
    }
    if (!response.ok) {
      response.body?.cancel().catch(() => undefined);
      throw new ApiError(422, "SOURCE_HTTP_ERROR", `The page responded with HTTP ${response.status}`);
    }
    const header = response.headers.get("content-type") ?? "";
    const [type, ...params] = header.split(";").map((part) => part.trim());
    const charset = params.find((param) => param.toLowerCase().startsWith("charset="))?.slice(8).replace(/["']/g, "");
    return { url, contentType: (type || "application/octet-stream").toLowerCase(), charset, bytes: await readCapped(response, maxBytes) };
  }
  throw new ApiError(422, "SOURCE_UNREACHABLE", "The page redirected too many times");
}

/** Decodes text using the header charset, then a `<meta charset>` sniff, then UTF-8. */
export function decodeText(bytes: Uint8Array, charset?: string): string {
  let label = charset;
  if (!label) {
    const head = new TextDecoder("latin1").decode(bytes.subarray(0, 4096));
    label = /<meta[^>]+charset=["']?([\w-]+)/i.exec(head)?.[1];
  }
  try {
    return new TextDecoder(label || "utf-8").decode(bytes);
  } catch {
    return new TextDecoder("utf-8").decode(bytes);
  }
}
