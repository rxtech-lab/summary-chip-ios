import { and, eq, lt, or } from "drizzle-orm";
import { randomBytes } from "node:crypto";
import { z } from "zod";
import type { Database } from "@/lib/db/client";
import { miniAppConnections as connections, miniAppConnectionGrants as grants, miniAppOAuth, miniAppMembers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { jsonValue, miniId, validateFields, type Json, type MiniConnector } from "@/lib/contracts/mini-app";
import { miniAccess } from "./service";
import { fingerprint, seal, unseal } from "./secrets";
import { assertPublicUrlSyntax } from "@/lib/extract/ssrf";
import { brokerRequest } from "./http";

type Secret = { apiKey?: string; clientSecret?: string; accessToken?: string; refreshToken?: string; expiresAt?: number };
export const connectSchema = z.object({ connector: miniId, shared: z.boolean().default(false), apiKey: z.string().min(1).max(8192).optional(), clientSecret: z.string().max(8192).optional() }).strict();
const binding = (row: { id: string; appId: string; userId: string; connector: string }) => `mini-connection:${row.appId}:${row.userId}:${row.connector}:${row.id}`;
function connectorOf(access: Awaited<ReturnType<typeof miniAccess>>, key: string): MiniConnector {
  const c = access.app.document.connectors[key];
  if (!c) throw new ApiError(404, "MINI_CONNECTOR_NOT_FOUND", "Connector not found");
  return c;
}
function callbackUrl(appId: string, connector: string) {
  const origin = process.env.NEXT_PUBLIC_SITE_URL;
  if (!origin || new URL(origin).protocol !== "https:") throw new ApiError(503, "MINI_OAUTH_NOT_CONFIGURED", "Configure the HTTPS site URL");
  return `${new URL(origin).origin}/api/v1/mini-apps/${encodeURIComponent(appId)}/connections/${encodeURIComponent(connector)}/callback`;
}
async function saveConnection(db: Database, appId: string, userId: string, connector: string, shared: boolean, spec: MiniConnector, secret: Secret) {
  const [previous] = await db.select().from(connections).where(and(eq(connections.appId, appId), eq(connections.userId, userId), eq(connections.connector, connector), eq(connections.shared, shared)));
  const id = previous?.id ?? crypto.randomUUID(); const row = { id, appId, userId, connector };
  const saved = previous
    ? await db.update(connections).set({ secret: seal(secret, binding(row)), fingerprint: fingerprint(spec), status: "connected", refreshLease: 0, revision: previous.revision + 1, updatedAt: new Date() }).where(and(eq(connections.id, id), eq(connections.revision, previous.revision))).returning()
    : await db.insert(connections).values({ ...row, shared, fingerprint: fingerprint(spec), secret: seal(secret, binding(row)) }).onConflictDoNothing().returning();
  if (!saved.length) throw new ApiError(409, "MINI_CONNECTION_CONFLICT", "Another connection setup completed first. Reload Connections.");
  // Reconnection never silently carries old delegation to a changed connector.
  await db.delete(grants).where(eq(grants.connectionId, id));
  return { id, status: "connected" };
}
export async function listConnections(db: Database, appId: string, userId: string) {
  const access = await miniAccess(db, appId, userId);
  const rows = await db.select().from(connections).where(and(eq(connections.appId, appId), or(eq(connections.userId, userId), eq(connections.shared, true))));
  const items = [];
  for (const row of rows) {
    const [grant] = await db.select().from(grants).where(and(eq(grants.connectionId, row.id), eq(grants.email, access.email)));
    if (row.userId !== userId && !grant) continue;
    items.push({ id: row.id, connector: row.connector, shared: row.shared, isOwner: row.userId === userId, status: fingerprint(access.app.document.connectors[row.connector]) === row.fingerprint ? row.status : "reauthorize", operations: row.userId === userId ? Object.keys(access.app.document.connectors[row.connector]?.operations ?? {}) : grant?.operations ?? [] });
  }
  return { items };
}
export async function connectMiniApp(db: Database, appId: string, userId: string, raw: unknown) {
  const input = connectSchema.parse(raw); const access = await miniAccess(db, appId, userId);
  if (input.shared && !access.owner) throw new ApiError(403, "MINI_CONNECTION_FORBIDDEN", "Only the app owner can create a shared connection");
  const spec = connectorOf(access, input.connector);
  if (spec.auth.type === "none") throw new ApiError(422, "MINI_CONNECTION_NOT_REQUIRED", "This API is public and needs no connection");
  if (spec.auth.type === "apiKey") {
    if (!input.apiKey || /[\r\n]/.test(input.apiKey)) throw new ApiError(422, "MINI_KEY_REQUIRED", "Enter a valid API key");
    return saveConnection(db, appId, userId, input.connector, input.shared, spec, { apiKey: input.apiKey });
  }
  const state = randomBytes(32).toString("base64url"); const verifier = randomBytes(32).toString("base64url");
  const stateHash = fingerprint(state);
  const redirect = callbackUrl(appId, input.connector);
  const authorization = new URL(spec.auth.authorizationUrl);
  assertPublicUrlSyntax(authorization);
  for (const [key, value] of Object.entries({ response_type: "code", client_id: spec.auth.clientId, redirect_uri: redirect, scope: spec.auth.scopes.join(" "), state, code_challenge_method: "S256", code_challenge: (await import("node:crypto")).createHash("sha256").update(verifier).digest("base64url") })) authorization.searchParams.set(key, value);
  await db.delete(miniAppOAuth).where(lt(miniAppOAuth.expiresAt, Date.now()));
  await db.insert(miniAppOAuth).values({ stateHash, appId, userId, connector: input.connector, shared: input.shared, fingerprint: fingerprint(spec), secret: seal({ verifier, clientSecret: input.clientSecret, redirect }, `mini-oauth:${stateHash}:${userId}:${appId}`), expiresAt: Date.now() + 10 * 60_000 });
  return { authorizationUrl: authorization.href, callbackScheme: "summarychip", status: "pending" };
}
async function tokenRequest(spec: MiniConnector, parameters: Record<string, string>, clientSecret?: string): Promise<Secret> {
  if (spec.auth.type !== "oauth2") throw new ApiError(422, "MINI_OAUTH_INVALID", "OAuth is not configured");
  const body = new URLSearchParams({ ...parameters, client_id: spec.auth.clientId, ...(clientSecret ? { client_secret: clientSecret } : {}) });
  const result = await brokerRequest(new URL(spec.auth.tokenUrl), "POST", { "content-type": "application/x-www-form-urlencoded", accept: "application/json" }, body.toString());
  if (result.status < 200 || result.status >= 300) throw new ApiError(401, "MINI_RECONNECT_REQUIRED", "Reconnect the external account");
  let data: { access_token: string; refresh_token?: string; expires_in?: number };
  try { data = z.object({ access_token: z.string().min(1).max(8192).refine(v => !/[\r\n]/.test(v)), refresh_token: z.string().max(8192).optional(), token_type: z.string().refine(v => v.toLowerCase() === "bearer").optional(), expires_in: z.coerce.number().positive().max(315360000).optional() }).parse(JSON.parse(result.body)); }
  catch { throw new ApiError(502, "MINI_OAUTH_INVALID", "The provider returned an invalid token response"); }
  return { accessToken: data.access_token, refreshToken: data.refresh_token, expiresAt: data.expires_in ? Date.now() + data.expires_in * 1000 : undefined, clientSecret };
}
export async function finishMiniOAuth(db: Database, appId: string, connector: string, params: URLSearchParams, receivedCallback?: string) {
  const state = params.get("state"); if (!state) throw new ApiError(400, "MINI_OAUTH_STATE", "Missing OAuth state");
  const hash = fingerprint(state);
  const [pending] = await db.delete(miniAppOAuth).where(and(eq(miniAppOAuth.stateHash, hash), eq(miniAppOAuth.appId, appId), eq(miniAppOAuth.connector, connector))).returning();
  if (!pending || pending.expiresAt < Date.now()) throw new ApiError(400, "MINI_OAUTH_STATE", "OAuth request expired or was already used");
  if (params.has("error")) return { status: "cancelled" };
  const code = params.get("code"); if (!code || code.length > 8192) throw new ApiError(400, "MINI_OAUTH_CODE", "Missing authorization code");
  const access = await miniAccess(db, appId, pending.userId); const spec = connectorOf(access, connector);
  if (fingerprint(spec) !== pending.fingerprint) throw new ApiError(409, "MINI_RECONNECT_REQUIRED", "Connector changed; connect again");
  const secret = unseal<{ verifier: string; clientSecret?: string; redirect: string }>(pending.secret, `mini-oauth:${hash}:${pending.userId}:${appId}`);
  if (receivedCallback && receivedCallback !== secret.redirect) throw new ApiError(400, "MINI_OAUTH_CALLBACK", "OAuth callback did not match the initiating request");
  const tokens = await tokenRequest(spec, { grant_type: "authorization_code", code, code_verifier: secret.verifier, redirect_uri: secret.redirect }, secret.clientSecret);
  return saveConnection(db, appId, pending.userId, connector, pending.shared, spec, tokens);
}
export async function disconnectMini(db: Database, appId: string, userId: string, id: string) {
  await miniAccess(db, appId, userId);
  const [row] = await db.delete(connections).where(and(eq(connections.id, id), eq(connections.appId, appId), eq(connections.userId, userId))).returning();
  if (!row) throw new ApiError(404, "NOT_FOUND", "Connection not found");
  const access = await miniAccess(db, appId, userId); const spec = access.app.document.connectors[row.connector];
  if (spec?.auth.type === "oauth2" && spec.auth.revocationUrl) {
    try {
      const secret = unseal<Secret>(row.secret, binding(row));
      await brokerRequest(new URL(spec.auth.revocationUrl), "POST", { "content-type": "application/x-www-form-urlencoded" }, new URLSearchParams({ token: secret.refreshToken ?? secret.accessToken ?? "", client_id: spec.auth.clientId, ...(secret.clientSecret ? { client_secret: secret.clientSecret } : {}) }).toString());
    } catch { /* Local revocation remains effective when the provider is unavailable. */ }
  }
}
export async function grantMiniConnection(db: Database, appId: string, userId: string, id: string, email: string, operations: string[]) {
  const access = await miniAccess(db, appId, userId, true);
  const [row] = await db.select().from(connections).where(and(eq(connections.id, id), eq(connections.appId, appId), eq(connections.userId, userId), eq(connections.shared, true)));
  if (!row) throw new ApiError(404, "NOT_FOUND", "Shared connection not found");
  const spec = connectorOf(access, row.connector);
  if (fingerprint(spec) !== row.fingerprint || operations.some(op => !spec.operations[op])) throw new ApiError(409, "MINI_RECONNECT_REQUIRED", "Reconnect before granting these operations");
  const [member] = await db.select().from(miniAppMembers).where(and(eq(miniAppMembers.appId, appId), eq(miniAppMembers.email, email)));
  if (!member) throw new ApiError(422, "MINI_MEMBER_REQUIRED", "Invite this member before granting connection access");
  await db.insert(grants).values({ connectionId: id, email, operations }).onConflictDoUpdate({ target: [grants.connectionId, grants.email], set: { operations } });
}
type MiniOperation = MiniConnector["operations"][string];
function buildRequest(spec: MiniConnector, op: MiniOperation, values: Record<string, Json>) {
  const url = new URL(op.path, spec.origin);
  if (url.origin !== spec.origin) throw new ApiError(422, "MINI_ORIGIN_INVALID", "API origin changed");
  const headers: Record<string, string> = { accept: "application/json" };
  let body: string | undefined;
  if (op.method === "GET") for (const [key, value] of Object.entries(values)) { if (value !== null && value !== undefined) url.searchParams.set(key, typeof value === "object" ? JSON.stringify(value) : String(value)); }
  else { headers["content-type"] = "application/json"; body = JSON.stringify(values); }
  return { url, headers, body };
}
function parseResponse(status: number, text: string): Json {
  if (status < 200 || status >= 300) throw new ApiError(502, "MINI_API_ERROR", `The API returned HTTP ${status}`);
  if (!text.trim()) return null;
  try { return jsonValue.parse(JSON.parse(text)); } catch { throw new ApiError(502, "MINI_API_INVALID", "The API did not return supported JSON"); }
}
/** Public connectors carry no credential, so there is no connection row, grant or redaction to apply. */
async function callPublicConnector(spec: MiniConnector, op: MiniOperation, values: Record<string, Json>): Promise<Json> {
  const { url, headers, body } = buildRequest(spec, op, values);
  const result = await brokerRequest(url, op.method, headers, body);
  return parseResponse(result.status, result.body);
}
export async function callMiniConnector(db: Database, appId: string, userId: string, connector: string, operation: string, input: Json): Promise<Json> {
  const access = await miniAccess(db, appId, userId); const spec = connectorOf(access, connector); const op = spec.operations[operation];
  if (!op) throw new ApiError(404, "MINI_OPERATION_NOT_FOUND", "API operation not found");
  const values = validateFields(input, op.input);
  if (spec.auth.type === "none") return callPublicConnector(spec, op, values);
  const rows = await db.select().from(connections).where(and(eq(connections.appId, appId), eq(connections.connector, connector), eq(connections.status, "connected"), or(eq(connections.userId, userId), eq(connections.shared, true))));
  let row = rows.find(r => r.userId === userId && !r.shared);
  if (!row) for (const candidate of rows.filter(r => r.shared)) {
    const [grant] = await db.select().from(grants).where(and(eq(grants.connectionId, candidate.id), eq(grants.email, access.email)));
    if (candidate.userId === userId || grant?.operations.includes(operation)) { row = candidate; break; }
  }
  if (!row || row.fingerprint !== fingerprint(spec)) throw new ApiError(409, "MINI_RECONNECT_REQUIRED", "Connect or authorize this API operation in Connections");
  let secret = unseal<Secret>(row.secret, binding(row));
  if (spec.auth.type === "oauth2" && secret.expiresAt && secret.expiresAt <= Date.now() + 30_000) {
    if (!secret.refreshToken) throw new ApiError(401, "MINI_RECONNECT_REQUIRED", "This account needs to be reconnected");
    const [lease] = await db.update(connections).set({ refreshLease: Date.now() + 30_000 }).where(and(eq(connections.id, row.id), eq(connections.revision, row.revision), lt(connections.refreshLease, Date.now()))).returning();
    if (!lease) throw new ApiError(409, "MINI_REFRESH_BUSY", "This connection is refreshing. Try again shortly.");
    try {
      const next = await tokenRequest(spec, { grant_type: "refresh_token", refresh_token: secret.refreshToken }, secret.clientSecret);
      secret = { ...next, refreshToken: next.refreshToken ?? secret.refreshToken };
      const changed = await db.update(connections).set({ secret: seal(secret, binding(row)), revision: row.revision + 1, refreshLease: 0 }).where(and(eq(connections.id, row.id), eq(connections.revision, row.revision))).returning();
      if (!changed.length) throw new Error("Revoked during refresh");
      row = changed[0];
    } catch { await db.update(connections).set({ status: "reconnect", refreshLease: 0 }).where(and(eq(connections.id, row.id), eq(connections.revision, row.revision))); throw new ApiError(401, "MINI_RECONNECT_REQUIRED", "Reconnect the external account"); }
  }
  const { url, headers, body } = buildRequest(spec, op, values);
  if (spec.auth.type === "apiKey") headers[spec.auth.header] = spec.auth.prefix + secret.apiKey;
  else headers.authorization = `Bearer ${secret.accessToken}`;
  // A rekey on use rotates at-rest ciphertext without revealing plaintext to the caller.
  await db.update(connections).set({ secret: seal(secret, binding(row)) }).where(and(eq(connections.id, row.id), eq(connections.fingerprint, row.fingerprint), eq(connections.revision, row.revision)));
  // Refresh and encryption may await I/O; recheck revocation immediately before dispatch.
  const current = await miniAccess(db, appId, userId);
  const [active] = await db.select().from(connections).where(and(eq(connections.id, row.id), eq(connections.revision, row.revision), eq(connections.status, "connected")));
  const [grant] = await db.select().from(grants).where(and(eq(grants.connectionId, row.id), eq(grants.email, current.email)));
  if (!active || fingerprint(current.app.document.connectors[connector]) !== row.fingerprint || (row.userId !== userId && !grant?.operations.includes(operation))) throw new ApiError(403, "MINI_CONNECTION_FORBIDDEN", "Connection access changed");
  const result = await brokerRequest(url, op.method, headers, body);
  if (result.status === 401) {
    await db.update(connections).set({ status: "reconnect" }).where(and(eq(connections.id, row.id), eq(connections.revision, row.revision)));
    throw new ApiError(401, "MINI_RECONNECT_REQUIRED", "The external credential expired or was revoked. Reconnect this account.");
  }
  let sanitized = result.body;
  for (const value of [secret.apiKey, secret.accessToken, secret.refreshToken, secret.clientSecret]) if (value) sanitized = sanitized.replaceAll(value, "[redacted]");
  return parseResponse(result.status, sanitized);
}
