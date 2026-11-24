import { createGateway, type GatewayProvider } from "@ai-sdk/gateway";
import { getVercelOidcToken } from "@vercel/oidc";
import { createCipheriv, randomBytes } from "node:crypto";
import { z } from "zod";
import { ApiError } from "@/lib/http/errors";

function flowcyOrigin(): URL {
  const url = new URL(process.env.FLOWCY_BASE_URL?.trim() || "https://www.flowcy.dev");
  if (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))) {
    throw new Error("FLOWCY_BASE_URL requires HTTPS or a local development server");
  }
  return url;
}

const catalog = z.object({ models: z.array(z.object({ modelId: z.string().min(1).max(200), alias: z.string().min(1) })) });
const usage = z.object({
  unit: z.literal("micro_usd"),
  meters: z.array(z.object({
    key: z.string().min(1), used: z.number().nonnegative(), limit: z.number().nonnegative().nullable(),
    resetsAt: z.iso.datetime({ offset: true }).nullable(),
  })),
});

async function readAccountResource<T>(path: string, authorization: string, signal: AbortSignal, schema: z.ZodType<T>,
  resource: string, code: string): Promise<T> {
  const url = new URL(path, flowcyOrigin());
  const response = await fetch(url, {
    headers: { authorization }, redirect: "error", cache: "no-store",
    signal: AbortSignal.any([signal, AbortSignal.timeout(15_000)]),
  }).catch(() => {
    signal.throwIfAborted();
    throw new ApiError(503, code + "_UNAVAILABLE", `Flowcy could not load ${resource}. Try again.`);
  });
  if (!response.ok) throw new ApiError(response.status, code + "_UNAVAILABLE",
    response.status === 401 ? `Sign in again to load ${resource}.` : `Flowcy could not load ${resource}.`);
  const parsed = schema.safeParse(await response.json().catch(() => null));
  if (!parsed.success) throw new ApiError(502, code + "_INVALID", `Flowcy returned an unreadable response for ${resource}.`);
  return parsed.data;
}

export async function flowcyChatModels(authorization: string, signal: AbortSignal) {
  const result = await readAccountResource("/api/v1/agent/models?label=chat", authorization, signal, catalog, "the model catalog", "FLOWCY_CATALOG");
  return result.models;
}

export function flowcyModelUsage(authorization: string, signal: AbortSignal) {
  return readAccountResource("/api/v1/agent/usage", authorization, signal, usage, "model usage", "FLOWCY_USAGE");
}

const inferencePrefix = "/api/v1/chippy/inference/";
const inlineLimit = 3 * 1024 * 1024;
const uploadTicket = z.object({ key: z.string(), url: z.string().url(), headers: z.record(z.string(), z.string()) });

/** Chippy owns the points ledger, including for durable jobs without an active user session. */
async function serviceAuthorization(): Promise<string> {
  const token = process.env.FLOWCY_SERVICE_TOKEN?.trim() || await getVercelOidcToken();
  return "Bearer " + token;
}

/** The SDK serializes its complete tool/structured-output protocol here. Only Flowcy receives the service credential. */
export async function flowcyInference(operation: string, init: RequestInit = {}): Promise<Response> {
  const destination = new URL(inferencePrefix + operation, flowcyOrigin());
  const headers = new Headers(init.headers);
  headers.set("authorization", await serviceAuthorization());
  const options: RequestInit = { ...init, headers, cache: "no-store", redirect: "error" };
  if (typeof init.body === "string" && Buffer.byteLength(init.body) > inlineLimit) {
    // Private chat files and transcription audio can exceed Vercel's request limit.
    // Only ciphertext goes into staging; the per-request decryption key goes directly to Flowcy.
    const key = randomBytes(32);
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", key, iv);
    const encrypted = Buffer.concat([cipher.update(init.body, "utf8"), cipher.final()]);
    const ticket = await fetch(new URL(inferencePrefix + "upload", destination), {
      ...options, method: "POST", headers: { authorization: headers.get("authorization")!, "content-type": "application/json" },
      body: JSON.stringify({ bytes: encrypted.length }),
    });
    if (!ticket.ok) return ticket;
    const upload = uploadTicket.parse(await ticket.json());
    const put = await fetch(upload.url, {
      method: "PUT", headers: upload.headers, body: encrypted, redirect: "error", signal: init.signal,
    });
    if (!put.ok) throw new Error("Flowcy input upload failed (HTTP " + put.status + ")");
    headers.set("x-flowcy-input", upload.key);
    headers.delete("content-length");
    options.body = JSON.stringify({ key: key.toString("base64"), iv: iv.toString("base64"), tag: cipher.getAuthTag().toString("base64") });
  }
  return fetch(destination, options);
}

let provider: GatewayProvider | undefined;
export function flowcyGateway(): GatewayProvider {
  // Keep the SDK's standard WebSocket URL for the short-lived token minted through Flowcy.
  provider ??= createGateway({
    apiKey: process.env.FLOWCY_SERVICE_TOKEN?.trim() || undefined,
    fetch: async (input, init) => {
      const url = new URL(input instanceof Request ? input.url : input);
      const operation = url.pathname === "/v1/realtime/client-secrets" ? "realtime-token"
        : url.pathname.match(/^\/v4\/ai\/([a-z-]+)$/)?.[1];
      if (!operation) throw new Error("Unsupported Flowcy inference operation");
      return flowcyInference(operation, init);
    },
  });
  return provider;
}
