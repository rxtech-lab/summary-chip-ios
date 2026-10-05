import { generateKeyPair, SignJWT } from "jose";
import { MockAiProvider } from "@/lib/ai/mock";
import { setAiProviderForTests } from "@/lib/ai/provider";
import { setBearerConfigForTests } from "@/lib/auth/bearer";
import { createDatabase, setDatabaseForTests, type DatabaseHandle } from "@/lib/db/client";
import { setHostResolverForTests } from "@/lib/extract/ssrf";
import { MockFlightProvider } from "@/lib/flights/mock";
import { setFlightProviderForTests } from "@/lib/flights/provider";
import { setFlightTrackerForTests, type FlightTracker } from "@/lib/flights/tracker";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";

export const ISSUER = "https://auth.test.example";
export const CLIENT_ID = "ios-test-client";

let keys: Awaited<ReturnType<typeof generateKeyPair>> | undefined;

export async function signToken(sub: string, claims: Record<string, unknown> = {}): Promise<string> {
  keys ??= await generateKeyPair("RS256");
  return new SignJWT({ client_id: CLIENT_ID, ...claims })
    .setProtectedHeader({ alg: "RS256", kid: "test" })
    .setIssuer(ISSUER)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(keys.privateKey);
}

export interface TestEnv {
  handle: DatabaseHandle;
  store: MemoryObjectStore;
  ai: MockAiProvider;
  /** Records the flights whose tracking workflow was started (no workflow runtime in tests). */
  tracker: FlightTracker & { started: string[] };
  tokens: Record<"alice" | "bob", string>;
  teardown: () => void;
}

/** Fresh in-memory libsql database (migrated), memory object store, mock AI and local JWKS. */
export async function setupTestEnv(): Promise<TestEnv> {
  keys ??= await generateKeyPair("RS256");
  setBearerConfigForTests({ issuer: ISSUER, allowedClientIds: new Set([CLIENT_ID]), key: keys.publicKey });
  const handle = createDatabase(":memory:");
  await handle.migrate();
  setDatabaseForTests(handle.db);
  const store = new MemoryObjectStore();
  setObjectStoreForTests(store);
  const ai = new MockAiProvider();
  setAiProviderForTests(ai);
  setHostResolverForTests(async (hostname) => (hostname.endsWith(".internal-test") ? ["10.0.0.5"] : ["93.184.216.34"]));
  setFlightProviderForTests(new MockFlightProvider());
  const started: string[] = [];
  const tracker = { started, start: async (flightId: string) => { started.push(flightId); return `run-${started.length}`; }, isActive: async () => true };
  setFlightTrackerForTests(tracker);
  const tokens = { alice: await signToken("user-alice"), bob: await signToken("user-bob") };
  return {
    handle,
    store,
    ai,
    tracker,
    tokens,
    teardown: () => {
      setDatabaseForTests(undefined);
      setObjectStoreForTests(undefined);
      setAiProviderForTests(undefined);
      setBearerConfigForTests(undefined);
      setHostResolverForTests(undefined);
      setFlightProviderForTests(undefined);
      setFlightTrackerForTests(undefined);
      handle.close();
    },
  };
}

export function apiRequest(method: string, path: string, options: { token?: string; body?: unknown; headers?: Record<string, string> } = {}): Request {
  const headers = new Headers(options.headers);
  if (options.token) headers.set("authorization", `Bearer ${options.token}`);
  if (options.body !== undefined) headers.set("content-type", "application/json");
  return new Request(`http://localhost${path}`, {
    method,
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
  });
}

export function params<T extends Record<string, string>>(value: T) {
  return { params: Promise.resolve(value) };
}

/** Builds a small valid PDF. With `text` it has a real text layer; without, it is image-less and text-less ("scanned"). */
export function buildPdf(text?: string): Uint8Array {
  const escape = (value: string) => value.replace(/[\\()]/g, (char) => `\\${char}`);
  const lines = text ? text.match(/.{1,80}(\s|$)/g) ?? [text] : [];
  const stream = lines.length
    ? `BT /F1 12 Tf 50 750 Td 14 TL ${lines.map((line) => `(${escape(line.trim())}) Tj T*`).join(" ")} ET`
    : "0 0 1 rg 50 50 100 100 re f";
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ];
  let body = "%PDF-1.4\n";
  const offsets: number[] = [];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(body));
    body += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(body);
  body += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`).join("")}`;
  body += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return new Uint8Array(Buffer.from(body, "latin1"));
}

export function pngSize(bytes: Uint8Array): { width: number; height: number } | null {
  if (bytes[0] !== 0x89 || bytes[1] !== 0x50) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}
