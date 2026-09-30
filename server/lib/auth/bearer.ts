import { createRemoteJWKSet, jwtVerify, type JWTPayload, type JWTVerifyGetKey } from "jose";
import { ApiError } from "@/lib/http/errors";

export interface ApiPrincipal {
  sub: string;
  clientId: string;
  email?: string;
  name?: string;
  scopes: string[];
}

export interface BearerVerifierConfig {
  issuer: string;
  allowedClientIds: ReadonlySet<string>;
  key?: JWTVerifyGetKey | CryptoKey;
}

function normalizeIssuer(value: string): string {
  return value.replace(/\/$/, "");
}

const remoteJwks = new Map<string, JWTVerifyGetKey>();

function getRemoteKey(issuer: string): JWTVerifyGetKey {
  let key = remoteJwks.get(issuer);
  if (!key) {
    key = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`));
    remoteJwks.set(issuer, key);
  }
  return key;
}

let testConfig: BearerVerifierConfig | undefined;

/** Lets tests verify against a locally generated key pair instead of the remote JWKS. */
export function setBearerConfigForTests(config?: BearerVerifierConfig): void {
  testConfig = config;
}

export function getBearerVerifierConfig(): BearerVerifierConfig {
  if (testConfig) return testConfig;
  const issuer = process.env.AUTH_ISSUER || "https://auth.rxlab.app";
  const ids = [
    ...(process.env.RXLAB_ALLOWED_CLIENT_IDS ?? "").split(","),
    process.env.IOS_OAUTH_CLIENT_ID ?? "",
  ].map((value) => value.trim()).filter(Boolean);
  if (ids.length === 0) {
    throw new ApiError(503, "AUTH_NOT_CONFIGURED", "No allowed OAuth client IDs are configured");
  }
  return { issuer: normalizeIssuer(issuer), allowedClientIds: new Set(ids) };
}

function toPrincipal(payload: JWTPayload, allowedClientIds: ReadonlySet<string>): ApiPrincipal {
  const clientId = typeof payload.client_id === "string" ? payload.client_id : undefined;
  if (!clientId || !allowedClientIds.has(clientId)) {
    throw new ApiError(403, "OAUTH_CLIENT_NOT_ALLOWED", "This OAuth client cannot access Summary Chip");
  }
  if (typeof payload.sub !== "string" || payload.sub.length === 0) {
    throw new ApiError(401, "INVALID_ACCESS_TOKEN", "The access token is missing a subject");
  }
  const scope = typeof payload.scope === "string" ? payload.scope.split(/\s+/).filter(Boolean) : [];
  return {
    sub: payload.sub,
    clientId,
    email: typeof payload.email === "string" ? payload.email : undefined,
    name: typeof payload.name === "string" ? payload.name : undefined,
    scopes: scope,
  };
}

export async function verifyBearerToken(
  token: string,
  config: BearerVerifierConfig = getBearerVerifierConfig(),
): Promise<ApiPrincipal> {
  const issuer = normalizeIssuer(config.issuer);
  const key = config.key ?? getRemoteKey(issuer);
  try {
    const { payload } = await jwtVerify(token, key as JWTVerifyGetKey, {
      issuer,
      algorithms: ["RS256"],
      requiredClaims: ["sub", "exp", "client_id"],
    });
    return toPrincipal(payload, config.allowedClientIds);
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(401, "INVALID_ACCESS_TOKEN", "The bearer token is invalid or expired");
  }
}

function bearerToken(request: Request): string | null {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7).trim();
  return token || null;
}

export async function requireApiPrincipal(request: Request): Promise<ApiPrincipal> {
  const token = bearerToken(request);
  if (!token) throw new ApiError(401, "MISSING_ACCESS_TOKEN", "A bearer access token is required");
  return verifyBearerToken(token);
}

/** Best-effort principal for public routes that show extra data to a signed-in owner. */
export async function optionalApiPrincipal(request: Request): Promise<ApiPrincipal | null> {
  const token = bearerToken(request);
  if (!token) return null;
  try {
    return await verifyBearerToken(token);
  } catch {
    return null;
  }
}
