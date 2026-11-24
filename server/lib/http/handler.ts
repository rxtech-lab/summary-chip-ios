import { requireApiPrincipal, type ApiPrincipal } from "@/lib/auth/bearer";
import { appClient, requireAppFeature, type AppFeature } from "@/lib/http/app-version";
import { getDatabase, type Database } from "@/lib/db/client";
import { ApiError, errorResponse } from "@/lib/http/errors";
import { authenticateApiKey } from "@/lib/services/api-keys";
import { ACCESS_TOKEN_PREFIX, authChallenge } from "@/lib/mcp/oauth-config";
import { authenticateOAuthToken, type McpPrincipal } from "@/lib/mcp/oauth-tokens";
import { ensureUser } from "@/lib/services/users";
import { withAIAccount } from "@/lib/ai/model-preference";
import { subscriptionEnvironment, type SubscriptionEnvironment } from "@/lib/subscription/environment";
import { requireFlowcyAccess, withFlowcyRequest, type FlowcyAccess } from "@/lib/subscription/flowcy";

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
    app: formatApp(request),
  };
  const line = `[api] ${JSON.stringify(entry)}`;
  if (status >= 500) console.error(line);
  else if (status >= 400) console.warn(line);
  else if (process.env.NODE_ENV !== "test") console.log(line);
}

function formatApp(request: Request): string | undefined {
  const client = appClient(request);
  if (!client) return undefined;
  return [client.platform, client.version, client.build && `(${client.build})`].filter(Boolean).join(" ");
}

export interface ApiHandlerOptions {
  /** Answers `426 APP_UPDATE_REQUIRED` to apps older than the feature needs (`FEATURE_MIN_APP_VERSIONS`). */
  feature?: AppFeature;
  /** Answers `402 FLOWCY_SUBSCRIPTION_REQUIRED` when the caller does not have an active Flowcy Plus subscription. */
  requireSubscription?: boolean;
}

export interface ApiContext {
  principal: ApiPrincipal;
  db: Database;
  requestId: string;
  storeEnvironment: SubscriptionEnvironment;
}

/** Bearer-authenticated `/api/v1` handler: app version → auth → optional subscription check → ensure user row → action → consistent errors. */
export async function withApiAuth(
  request: Request,
  action: (context: ApiContext) => Promise<Response>,
  options: ApiHandlerOptions = {},
): Promise<Response> {
  const requestId = requestIdFor(request);
  const startedAt = performance.now();
  let principal: ApiPrincipal | undefined;
  let status = 500;
  try {
    if (options.feature) requireAppFeature(request, options.feature);
    principal = await requireApiPrincipal(request);
    const storeEnvironment = await subscriptionEnvironment(request);
    let initialAccess: FlowcyAccess | undefined;
    if (options.requireSubscription) {
      initialAccess = await requireFlowcyAccess(principal.sub, storeEnvironment);
    }
    const db = getDatabase();
    await ensureUser(db, principal);
    const context = { principal, db, requestId, storeEnvironment };
    const response = await withAIAccount(db, principal.sub, () =>
      withFlowcyRequest(context.principal.sub, storeEnvironment, () => action(context), initialAccess),
    );
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

export interface McpAuthContext {
  principal: McpPrincipal;
  db: Database;
  requestId: string;
}

/** MCP accepts resource-bound OAuth access tokens and existing personal API keys. Non-AI tools work without Flowcy Plus; AI tools gate individually. */
export async function withMcpAuth(request: Request, action: (context: McpAuthContext) => Promise<Response>): Promise<Response> {
  const requestId = requestIdFor(request);
  const startedAt = performance.now();
  let principal: McpPrincipal | undefined;
  let status = 500;
  try {
    const authorization = request.headers.get("authorization");
    const key = authorization?.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
    if (!key) throw new ApiError(401, "MISSING_API_KEY", "Sign in with OAuth or create an API key in Chippy → Settings → MCP Server.");
    const db = getDatabase();
    const oauth = key.startsWith(ACCESS_TOKEN_PREFIX);
    principal = await (oauth ? authenticateOAuthToken(db, key) : authenticateApiKey(db, key)) ?? undefined;
    if (!principal) throw new ApiError(401, oauth ? "INVALID_ACCESS_TOKEN" : "INVALID_API_KEY", "The credential is invalid, expired, or revoked.");
    const context = { principal, db, requestId };
    const response = await withAIAccount(db, principal.sub, () =>
      withFlowcyRequest(context.principal.sub, "production", () => action(context)),
    );
    status = response.status;
    response.headers.set("x-request-id", requestId);
    return response;
  } catch (error) {
    const response = errorResponse(error, requestId);
    status = response.status;
    if (status === 401) response.headers.set("www-authenticate", authChallenge(undefined, keyPresent(request) ? "invalid_token" : undefined));
    return response;
  } finally {
    log(request, requestId, status, startedAt, principal);
  }
}

function keyPresent(request: Request): boolean { return Boolean(request.headers.get("authorization")); }

/** Unauthenticated JSON handler with the same error envelope. */
export async function withPublicApi(
  request: Request,
  action: (context: { db: Database; requestId: string }) => Promise<Response>,
  options: ApiHandlerOptions = {},
): Promise<Response> {
  const requestId = requestIdFor(request);
  const startedAt = performance.now();
  let status = 500;
  try {
    if (options.feature) requireAppFeature(request, options.feature);
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
