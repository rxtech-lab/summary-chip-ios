import { createHash, randomBytes } from "node:crypto";
import { expect, test } from "@playwright/test";

const ORIGIN = "http://127.0.0.1:3100";
const RESOURCE = `${ORIGIN}/api/mcp`;

test("publishes MCP OAuth discovery and challenges unauthenticated agents", async ({ request }) => {
  const resource = await request.get("/.well-known/oauth-protected-resource");
  expect(resource.ok()).toBe(true);
  expect(await resource.json()).toMatchObject({ resource: RESOURCE, authorization_servers: [ORIGIN] });
  const alias = await request.get("/.well-known/oauth-protected-resource/api/mcp");
  expect(await alias.json()).toEqual(await resource.json());
  const metadata = await request.get("/.well-known/oauth-authorization-server");
  expect(await metadata.json()).toMatchObject({ issuer: ORIGIN, code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"] });
  const unauthenticated = await request.post("/api/mcp", { headers: { accept: "application/json, text/event-stream" },
    data: { jsonrpc: "2.0", id: 1, method: "tools/list" } });
  expect(unauthenticated.status()).toBe(401);
  expect(unauthenticated.headers()["www-authenticate"]).toContain(`resource_metadata="${ORIGIN}/.well-known/oauth-protected-resource"`);
});

test("connects through real HTTP login, consent, code exchange, MCP, refresh and revocation", async ({ request }) => {
  const callback = "https://agent.example/callback";
  const registration = await request.post("/api/mcp/oauth/register", { data: { client_name: "E2E agent", redirect_uris: [callback] } });
  expect(registration.status()).toBe(201);
  const clientId = (await registration.json()).client_id;
  const verifier = randomBytes(32).toString("base64url");
  const authorize = await request.get("/api/mcp/oauth/authorize", { maxRedirects: 0, params: {
    client_id: clientId, redirect_uri: callback, response_type: "code", resource: RESOURCE, scope: "chippy:read",
    code_challenge_method: "S256", code_challenge: createHash("sha256").update(verifier).digest("base64url"), state: "e2e-state",
  } });
  expect(authorize.status()).toBe(302);
  const signedIn = await request.get(authorize.headers().location, { maxRedirects: 0 });
  expect(signedIn.status()).toBe(302);
  const identity = await request.get(signedIn.headers().location, { maxRedirects: 0 });
  expect(identity.status()).toBe(302);
  const consent = await request.get(identity.headers().location);
  expect(consent.ok()).toBe(true);
  const html = await consent.text();
  expect(html).toContain("Connect E2E agent to Chippy?");
  const id = /name="request" value="([^"]+)"/.exec(html)![1];
  const csrf = /name="csrf" value="([^"]+)"/.exec(html)![1];
  const approved = await request.post("/api/mcp/oauth/consent", { maxRedirects: 0, headers: { origin: ORIGIN },
    form: { request: id, csrf, decision: "allow" } });
  expect(approved.status()).toBe(302);
  const target = new URL(approved.headers().location);
  expect(target.searchParams.get("state")).toBe("e2e-state");
  expect(target.searchParams.get("iss")).toBe(ORIGIN);
  const exchanged = await request.post("/api/mcp/oauth/token", { form: { grant_type: "authorization_code", client_id: clientId,
    redirect_uri: callback, resource: RESOURCE, code: target.searchParams.get("code")!, code_verifier: verifier } });
  expect(exchanged.ok()).toBe(true);
  const tokens = await exchanged.json();
  const rpc = (access: string, name: string) => request.post("/api/mcp", {
    headers: { authorization: `Bearer ${access}`, accept: "application/json, text/event-stream" },
    data: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: {} } },
  });
  const profile = await rpc(tokens.access_token, "get_profile");
  expect(profile.ok()).toBe(true);
  expect((await profile.json()).result.structuredContent.id).toMatch(/^e2e-mcp-/);
  expect((await (await rpc(tokens.access_token, "list_summaries")).json()).result.structuredContent.items).toEqual([]);
  const refreshed = await request.post("/api/mcp/oauth/token", { form: { grant_type: "refresh_token", client_id: clientId,
    resource: RESOURCE, refresh_token: tokens.refresh_token } });
  expect(refreshed.ok()).toBe(true);
  const rotated = await refreshed.json();
  expect(rotated.refresh_token).not.toBe(tokens.refresh_token);
  expect((await request.post("/api/mcp/oauth/revoke", { form: { client_id: clientId, token: rotated.refresh_token } })).ok()).toBe(true);
  expect((await rpc(rotated.access_token, "get_profile")).status()).toBe(401);
});
