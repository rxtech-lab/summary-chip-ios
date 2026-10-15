import { request } from "node:https";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { assertPublicUrlSyntax, isPrivateAddress } from "@/lib/extract/ssrf";
import { ApiError } from "@/lib/http/errors";
export type BrokerResponse = { status: number; body: string };
export type BrokerTransport = (url: URL, method: string, headers: Record<string, string>, body?: string) => Promise<BrokerResponse>;
let testTransport: BrokerTransport | undefined;
export function setMiniTransportForTests(transport?: BrokerTransport) {
  if (process.env.NODE_ENV !== "test") throw new Error("Test transport is test-only");
  testTransport = transport;
}
/** Resolves once, validates every address, and pins the TLS connection to that DNS result. */
export const brokerRequest: BrokerTransport = async (url, method, headers, body) => {
  assertPublicUrlSyntax(url);
  if (url.protocol !== "https:") throw new ApiError(422, "MINI_HTTPS_REQUIRED", "Connections require HTTPS");
  if (body && Buffer.byteLength(body) > 1024 * 1024) throw new ApiError(422, "MINI_REQUEST_TOO_LARGE", "Request exceeds 1 MiB");
  if (testTransport) return testTransport(url, method, headers, body);
  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  const addresses = isIP(hostname) ? [{ address: hostname, family: isIP(hostname) }] : await resolvePublicHost(hostname);
  if (!addresses.length || addresses.some(a => isPrivateAddress(a.address))) throw new ApiError(422, "URL_NOT_ALLOWED", "This address is not permitted");
  const pinned = addresses[0];
  return new Promise((resolve, reject) => {
    const req = request(url, { method, headers, agent: false, lookup: (_host, options, callback) => {
      if (options.all) callback(null, [pinned]); else callback(null, pinned.address, pinned.family);
    } }, response => {
      // Never follow redirects with connection credentials.
      if ((response.statusCode ?? 500) >= 300 && (response.statusCode ?? 500) < 400) { clearTimeout(timer); response.destroy(); reject(new ApiError(422, "MINI_REDIRECT_BLOCKED", "The API redirected. Configure its final HTTPS endpoint.")); return; }
      const chunks: Buffer[] = []; let bytes = 0;
      response.on("data", (chunk: Buffer) => {
        bytes += chunk.length;
        if (bytes > 1024 * 1024) req.destroy(new Error("Response limit")); else chunks.push(chunk);
      });
      response.once("end", () => { clearTimeout(timer); resolve({ status: response.statusCode ?? 502, body: Buffer.concat(chunks).toString("utf8") }); });
      response.once("error", () => { clearTimeout(timer); reject(new ApiError(502, "MINI_API_UNAVAILABLE", "The API response was interrupted")); });
    });
    const timer = setTimeout(() => req.destroy(new Error("Timeout")), 10_000);
    req.once("error", () => { clearTimeout(timer); reject(new ApiError(502, "MINI_API_UNAVAILABLE", "The API request did not complete")); });
    req.end(body);
  });
};

async function resolvePublicHost(hostname: string) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try { return await Promise.race([lookup(hostname, { all: true }), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new ApiError(504, "MINI_DNS_TIMEOUT", "API address lookup timed out")), 3000); })]); }
  finally { clearTimeout(timer); }
}
