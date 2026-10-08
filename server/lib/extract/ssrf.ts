import { lookup } from "node:dns/promises";
import { BlockList, isIP } from "node:net";
import { ApiError } from "@/lib/http/errors";

const blocked = new BlockList();
for (const [network, prefix] of [
  ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8], ["169.254.0.0", 16],
  ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.0.2.0", 24], ["192.88.99.0", 24], ["192.168.0.0", 16],
  ["198.18.0.0", 15], ["198.51.100.0", 24], ["203.0.113.0", 24], ["224.0.0.0", 4], ["240.0.0.0", 4],
] as const) blocked.addSubnet(network, prefix, "ipv4");
for (const [network, prefix] of [
  ["::", 128], ["::1", 128], ["fc00::", 7], ["fe80::", 10], ["ff00::", 8], ["2001:db8::", 32],
  ["64:ff9b::", 96], ["64:ff9b:1::", 48], ["100::", 64], ["2002::", 16],
] as const) blocked.addSubnet(network, prefix, "ipv6");

export function isPrivateAddress(address: string): boolean {
  const family = isIP(address);
  if (family === 4) return blocked.check(address, "ipv4");
  if (family === 6) {
    const lower = address.toLowerCase();
    // IPv4-mapped / -compatible addresses (::ffff:10.0.0.1) are judged by their IPv4 part.
    const mapped = /^(?:::ffff:|::)(\d+\.\d+\.\d+\.\d+)$/.exec(lower);
    if (mapped) return blocked.check(mapped[1], "ipv4");
    const hexMapped = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(lower);
    if (hexMapped) {
      const high = parseInt(hexMapped[1], 16);
      const low = parseInt(hexMapped[2], 16);
      return blocked.check(`${high >> 8}.${high & 255}.${low >> 8}.${low & 255}`, "ipv4");
    }
    return blocked.check(address, "ipv6");
  }
  return true;
}

export type HostResolver = (hostname: string) => Promise<string[]>;

const systemResolver: HostResolver = async (hostname) =>
  (await lookup(hostname, { all: true, verbatim: true })).map((entry) => entry.address);

let resolver: HostResolver = systemResolver;

export function setHostResolverForTests(value?: HostResolver): void {
  resolver = value ?? systemResolver;
}

const blockedUrl = () => new ApiError(422, "URL_NOT_ALLOWED", "This URL points to a private or unsupported address");

/**
 * Rejects what is not a public http(s) target by its text alone: other schemes, credentials,
 * local names and private literal addresses. Doesn't resolve the name.
 */
export function assertPublicUrlSyntax(raw: string | URL): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new ApiError(422, "INVALID_URL", "The URL is not valid");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") throw blockedUrl();
  if (url.username || url.password) throw blockedUrl();
  const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  if (!hostname || hostname === "localhost" || hostname.endsWith(".localhost") || hostname.endsWith(".local") || hostname.endsWith(".internal")) {
    throw blockedUrl();
  }
  if (isIP(hostname) && isPrivateAddress(hostname)) throw blockedUrl();
  return url;
}

/**
 * Rejects anything but public http(s) targets. Every address the name resolves to must be public.
 * (A DNS answer that changes between this check and the connection is not covered; redirects are
 * re-validated hop by hop by the fetcher.)
 */
export async function assertPublicUrl(raw: string | URL): Promise<URL> {
  const url = assertPublicUrlSyntax(raw);
  const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  if (isIP(hostname)) return url;
  let addresses: string[];
  try {
    addresses = await resolver(hostname);
  } catch {
    throw new ApiError(422, "URL_UNREACHABLE", "The URL's host could not be resolved");
  }
  if (addresses.length === 0 || addresses.some(isPrivateAddress)) throw blockedUrl();
  return url;
}
