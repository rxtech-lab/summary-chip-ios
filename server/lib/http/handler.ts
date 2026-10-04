import { requireApiPrincipal, type ApiPrincipal } from "@/lib/auth/bearer";
import { getDatabase, type Database } from "@/lib/db/client";
import { ApiError, errorResponse } from "@/lib/http/errors";
import { authenticateApiKey, type ApiKeyPrincipal } from "@/lib/services/api-keys";
import { ensureUser } from "@/lib/services/users";

function requestIdFor(request: Request): string {
  return request.headers.get("x-request-id")?.slice(0, 80) || crypto.randomUUID();
}

function log(request: Request, requestId: string, status: number, startedAt: number, principal?: ApiPrincipal) {
  const entry = {
    requestId,
    method: request.method,
    path: new URL(request.url).pathname,
    status,
    durationMs: Math.round(performance.now() - startedAt),
    user: principal?.sub,
  };
  const line = `[api] ${JSON.stringify(entry)}`;
  if (status >= 500) console.error(line);
  else if (status >= 400) console.warn(line);
  else if (process.env.NODE_ENV !== "test") console.log(line);
}

export interface ApiContext {
  principal: ApiPrincipal;
  db: Database;
  requestId: string;
}

/** Bearer-authenticated `/api/v1` handler: auth → ensure user row → action → consistent errors. */
export async function withApiAuth(request: Request, action: (context: ApiContext) => Promise<Response>): Promise<Response> {
  const requestId = requestIdFor(request);
  const startedAt = performance.now();
  let principal: ApiPrincipal | undefined;
  let status = 500;
  try {
    principal = await requireApiPrincipal(request);
    const db = getDatabase();
    await ensureUser(db, principal);
    const response = await action({ principal, db, requestId });
    status = response.status;
    response.headers.set("x-request-id", requestId);
    return response;
  } catch (error) {
    const response = errorResponse(error, requestId);
    status = response.status;
    return response;
  } finally {
    log(request, requestId, status, startedAt, principal);
  }
}

export interface ApiKeyContext {
  principal: ApiKeyPrincipal;
  db: Database;
  requestId: string;
}

/** Handler authenticated by a personal API key (`Authorization: Bearer chippy_…`), as used by the MCP server. */
export async function withApiKeyAuth(request: Request, action: (context: ApiKeyContext) => Promise<Response>): Promise<Response> {
  const requestId = requestIdFor(request);
  const startedAt = performance.now();
  let principal: ApiKeyPrincipal | undefined;
  let status = 500;
  try {
    const authorization = request.headers.get("authorization");
    const key = authorization?.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
    if (!key) throw new ApiError(401, "MISSING_API_KEY", "An API key is required. Create one in Chippy → Settings → MCP Server.");
    const db = getDatabase();
    principal = await authenticateApiKey(db, key) ?? undefined;
    if (!principal) throw new ApiError(401, "INVALID_API_KEY", "The API key is invalid or has been revoked.");
    const response = await action({ principal, db, requestId });
    status = response.status;
    response.headers.set("x-request-id", requestId);
    return response;
  } catch (error) {
    const response = errorResponse(error, requestId);
    status = response.status;
    if (status === 401) response.headers.set("www-authenticate", 'Bearer realm="chippy"');
    return response;
  } finally {
    log(request, requestId, status, startedAt, principal);
  }
}

/** Unauthenticated JSON handler with the same error envelope. */
export async function withPublicApi(request: Request, action: (context: { db: Database; requestId: string }) => Promise<Response>): Promise<Response> {
  const requestId = requestIdFor(request);
  const startedAt = performance.now();
  let status = 500;
  try {
    const response = await action({ db: getDatabase(), requestId });
    status = response.status;
    response.headers.set("x-request-id", requestId);
    return response;
  } catch (error) {
    const response = errorResponse(error, requestId);
    status = response.status;
    return response;
  } finally {
    log(request, requestId, status, startedAt);
  }
}
