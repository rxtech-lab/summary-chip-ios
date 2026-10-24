import { afterEach, beforeEach, expect, it } from "vitest";
import * as clientsRoute from "@/app/api/v1/mcp/clients/route";
import * as keysRoute from "@/app/api/v1/api-keys/route";
import { mcpOAuthClients, mcpOAuthGrants, users } from "@/lib/db/schema";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
beforeEach(async () => { env = await setupTestEnv(); });
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
