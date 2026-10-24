import { afterEach, beforeEach, expect, it } from "vitest";
import * as clientsRoute from "@/app/api/v1/mcp/clients/route";
import * as clientRoute from "@/app/api/v1/mcp/clients/[id]/route";
import * as keysRoute from "@/app/api/v1/api-keys/route";
import { mcpOAuthClients, mcpOAuthGrants, mcpOAuthTokens, users } from "@/lib/db/schema";
import { authenticateOAuthToken, exchangeRefresh } from "@/lib/mcp/oauth-tokens";
import { digest, mcpResource } from "@/lib/mcp/oauth-config";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
beforeEach(async () => { env = await setupTestEnv({ transactional: true }); });
afterEach(() => { env.teardown(); });

it("requires app authentication", async () => {
  expect((await clientsRoute.GET(apiRequest("GET", "/api/v1/mcp/clients"))).status).toBe(401);
  const created = await keysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token: env.tokens.alice, body: { name: "Agent" } }));
  const { key } = await created.json();
  expect((await clientsRoute.GET(apiRequest("GET", "/api/v1/mcp/clients", { token: key }))).status).toBe(401);
});

it("returns only the account's unexpired, unrevoked authorizations without credentials", async () => {
  const future = new Date(Date.now() + 86400_000);
  await env.handle.db.insert(users).values([{ id: "user-alice" }, { id: "user-bob" }]);
  await env.handle.db.insert(mcpOAuthClients).values({ id: "client", name: "Claude", redirectUris: ["https://private.example/callback"] });
  await env.handle.db.insert(mcpOAuthGrants).values([
    { id: "active", ownerId: "user-alice", clientId: "client", resource: "https://summary.test/api/mcp", scope: "chippy:read", expiresAt: future },
    { id: "other", ownerId: "user-bob", clientId: "client", resource: "https://summary.test/api/mcp", scope: "chippy:write", expiresAt: future },
    { id: "expired", ownerId: "user-alice", clientId: "client", resource: "https://summary.test/api/mcp", scope: "chippy:read", expiresAt: new Date(0) },
    { id: "revoked", ownerId: "user-alice", clientId: "client", resource: "https://summary.test/api/mcp", scope: "chippy:read", expiresAt: future, revokedAt: new Date() },
  ]);
  const response = await clientsRoute.GET(apiRequest("GET", "/api/v1/mcp/clients", { token: env.tokens.alice }));
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toContain("no-store");
  expect(await response.json()).toEqual({ items: [{ id: "active", clientId: "client", name: "Claude", scope: "chippy:read", expiresAt: future.toISOString() }] });
});

it("returns an empty list for an account without authorizations", async () => {
  const response = await clientsRoute.GET(apiRequest("GET", "/api/v1/mcp/clients", { token: env.tokens.alice }));
  expect(await response.json()).toEqual({ items: [] });
});

function disconnect(id: string, token?: string) {
  return clientRoute.DELETE(apiRequest("DELETE", `/api/v1/mcp/clients/${id}`, { token }), { params: Promise.resolve({ id }) });
}

async function seedAuthorization() {
  const expiresAt = new Date(Date.now() + 86400_000);
  await env.handle.db.insert(users).values([{ id: "user-alice" }, { id: "user-bob" }]);
  await env.handle.db.insert(mcpOAuthClients).values({ id: "client", name: "Cursor", redirectUris: ["https://example.com/callback"] });
  await env.handle.db.insert(mcpOAuthGrants).values([
    { id: "alice", ownerId: "user-alice", clientId: "client", resource: mcpResource(), scope: "chippy:read", expiresAt },
    { id: "alice-other", ownerId: "user-alice", clientId: "client", resource: mcpResource(), scope: "chippy:read", expiresAt },
    { id: "bob", ownerId: "user-bob", clientId: "client", resource: mcpResource(), scope: "chippy:read", expiresAt },
  ]);
  await env.handle.db.insert(mcpOAuthTokens).values([
    { hash: digest("chippy_oauth_test"), grantId: "alice", kind: "access", expiresAt },
    { hash: digest("refresh-test"), grantId: "alice", kind: "refresh", expiresAt },
    { hash: digest("chippy_oauth_other"), grantId: "alice-other", kind: "access", expiresAt },
  ]);
}

it("requires app authentication to disconnect, rejecting API keys and OAuth tokens", async () => {
  await seedAuthorization();
  expect((await disconnect("alice")).status).toBe(401);
  expect((await disconnect("alice", "chippy_oauth_test")).status).toBe(401);
  const created = await keysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token: env.tokens.alice, body: { name: "Agent" } }));
  expect((await disconnect("alice", (await created.json()).key)).status).toBe(401);
  expect(await authenticateOAuthToken(env.handle.db, "chippy_oauth_test")).not.toBeNull();
});

it("does not reveal or revoke another account's authorization", async () => {
  await seedAuthorization();
  expect((await disconnect("alice", env.tokens.bob)).status).toBe(404);
  expect((await disconnect("missing", env.tokens.bob)).status).toBe(404);
  expect(await authenticateOAuthToken(env.handle.db, "chippy_oauth_test")).not.toBeNull();
});

it("disconnects one grant, blocks access and refresh, and safely accepts a repeated disconnect", async () => {
  await seedAuthorization();
  expect(await authenticateOAuthToken(env.handle.db, "chippy_oauth_test")).not.toBeNull();
  const response = await disconnect("alice", env.tokens.alice);
  expect(response.status).toBe(204);
  expect(await response.text()).toBe("");
  expect(response.headers.get("cache-control")).toContain("no-store");
  expect(await authenticateOAuthToken(env.handle.db, "chippy_oauth_test")).toBeNull();
  await expect(exchangeRefresh(env.handle.db, { token: "refresh-test", clientId: "client", resource: mcpResource() })).rejects.toThrow("expired, revoked");
  expect(await authenticateOAuthToken(env.handle.db, "chippy_oauth_other")).not.toBeNull();
  expect((await disconnect("alice", env.tokens.alice)).status).toBe(204);
  const list = await clientsRoute.GET(apiRequest("GET", "/api/v1/mcp/clients", { token: env.tokens.alice }));
  expect((await list.json()).items.map((item: { id: string }) => item.id)).toEqual(["alice-other"]);
  const bob = await clientsRoute.GET(apiRequest("GET", "/api/v1/mcp/clients", { token: env.tokens.bob }));
  expect((await bob.json()).items.map((item: { id: string }) => item.id)).toEqual(["bob"]);
});
