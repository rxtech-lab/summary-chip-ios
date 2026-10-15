import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { setupTestEnv, apiRequest, params, type TestEnv } from "../helpers/setup";
import { users, miniAppMembers, miniAppConnections, miniAppRecords, summaries } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { miniAppExample, miniAppDocumentSchema, miniAppCatalog } from "@/lib/contracts/mini-app";
import { createMiniApp, getMiniApp, updateMiniApp, mutateMiniRecord, queryMiniRecords } from "@/lib/mini-app/service";
import { runMiniAction, previewMiniAction, runMiniScriptStep } from "@/lib/mini-app/runtime";
import { connectMiniApp, grantMiniConnection, callMiniConnector, finishMiniOAuth } from "@/lib/mini-app/connections";
import { setMiniTransportForTests, brokerRequest, type BrokerTransport } from "@/lib/mini-app/http";
import { seal, unseal } from "@/lib/mini-app/secrets";
import { runMiniScript } from "@/lib/mini-app/scripts";
import { validateMiniApp } from "@/lib/mini-app/validation";
import { listVersions, restoreVersion } from "@/lib/services/versions";
import * as miniRoute from "@/app/api/v1/mini-apps/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as membersRoute from "@/app/api/v1/mini-apps/[id]/members/route";
import * as keysRoute from "@/app/api/v1/api-keys/route";
import * as mcpRoute from "@/app/api/mcp/route";
import { toolScope } from "@/lib/mcp/oauth-config";
let env: TestEnv;
const example = () => structuredClone(miniAppExample);
const connector = { title: "Example", origin: "https://api.example.com", auth: { type: "apiKey", header: "Authorization", prefix: "Bearer " }, operations: { list: { method: "GET", path: "/items", input: {} } } };
beforeEach(async () => {
  env = await setupTestEnv();
  await env.handle.db.insert(users).values([{ id: "user-alice", email: "alice@example.com" }, { id: "user-bob", email: "bob@example.com" }]);
  vi.stubEnv("MINI_APP_SECRET_KEYS", JSON.stringify({ v1: Buffer.alloc(32, 7).toString("base64") }));
  vi.stubEnv("MINI_APP_ACTIVE_SECRET_KEY", "v1"); vi.stubEnv("NEXT_PUBLIC_SITE_URL", "https://chippy.example.com");
});
afterEach(() => { setMiniTransportForTests(); env?.teardown(); vi.unstubAllEnvs(); });
it("excludes Clips before Feed pagination while keeping the Clips list available", async () => {
  const clip = await createMiniApp(env.handle.db, "user-alice", example(), "agent");
  const [template] = await env.handle.db.select().from(summaries).where(eq(summaries.id, clip.id));
  const oldest = new Date("2026-01-01T00:00:00Z");
  for (const [id, kind] of [["feed-card", "summary"], ["feed-trip", "trip"], ["feed-paper", "paper"]] as const) {
    await env.handle.db.insert(summaries).values({
      ...template, id, slug: id, kind, title: id, createdAt: oldest, updatedAt: oldest,
    });
  }
  const list = async (query: string) => {
    const response = await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?${query}`, { token: env.tokens.alice }));
    expect(response.status).toBe(200);
    return response.json();
  };
  const first = await list("excludeKind=mini_app&limit=2");
  expect(first.items).toHaveLength(2);
  expect(first.items.every((item: { kind: string }) => item.kind !== "mini_app")).toBe(true);
  expect(first.nextCursor).toEqual(expect.any(String));
  const second = await list(`excludeKind=mini_app&limit=2&cursor=${encodeURIComponent(first.nextCursor)}`);
  expect(second.items).toHaveLength(1);
  expect(second.nextCursor).toBeNull();
  expect(new Set([...first.items, ...second.items].map((item: { kind: string }) => item.kind))).toEqual(new Set(["summary", "trip", "paper"]));
  const clips = await list("kind=mini_app");
  expect(clips.items.map((item: { id: string }) => item.id)).toEqual([clip.id]);
});
it("validates the catalog, versions, cycles and automatic writes", async () => {
  expect(miniAppCatalog().components).toContain("Sheet");
  expect((await validateMiniApp(example())).ok).toBe(true);
  expect((await validateMiniApp({ ...example(), schemaVersion: 2 })).ok).toBe(false);
  const cyclic = example(); cyclic.ui.elements.root.children.push("root");
  expect((await validateMiniApp(cyclic)).issues.join()).toContain("cyclic");
  const write = example(); write.ui.elements.root.events.load = "save";
  expect((await validateMiniApp(write)).issues.join()).toContain("read action");
});
it("isolates personal rows between members, apps and the app creator", async () => {
  const app = await createMiniApp(env.handle.db, "user-alice", example());
  await expect(getMiniApp(env.handle.db, app.id, "user-bob")).rejects.toMatchObject({ status: 404 });
  await env.handle.db.insert(miniAppMembers).values({ appId: app.id, email: "bob@example.com", permissions: {} });
  await mutateMiniRecord(env.handle.db, app.id, "user-bob", "tasks", "create", { data: { title: "Bob private" } });
  expect((await queryMiniRecords(env.handle.db, app.id, "user-alice", app.document.queries.tasks)).items).toHaveLength(0);
  expect((await queryMiniRecords(env.handle.db, app.id, "user-bob", app.document.queries.tasks)).items[0].data.title).toBe("Bob private");
  const second = await createMiniApp(env.handle.db, "user-bob", example());
  expect((await queryMiniRecords(env.handle.db, second.id, "user-bob", app.document.queries.tasks)).items).toHaveLength(0);
});
it("enforces and immediately revokes shared table grants", async () => {
  const doc = example(); doc.tables.tasks.scope = "shared";
  const app = await createMiniApp(env.handle.db, "user-alice", doc);
  await env.handle.db.insert(miniAppMembers).values({ appId: app.id, email: "bob@example.com", permissions: { tasks: "read" } });
  await mutateMiniRecord(env.handle.db, app.id, "user-alice", "tasks", "create", { data: { title: "Shared" } });
  expect((await queryMiniRecords(env.handle.db, app.id, "user-bob", doc.queries.tasks)).items).toHaveLength(1);
  await expect(mutateMiniRecord(env.handle.db, app.id, "user-bob", "tasks", "create", { data: { title: "denied" } })).rejects.toMatchObject({ status: 403 });
  const r = await membersRoute.PUT(apiRequest("PUT", "members", { token: env.tokens.alice, body: { email: "bob@example.com", remove: true } }), params({ id: app.id }));
  expect(r.status).toBe(200); await expect(getMiniApp(env.handle.db, app.id, "user-bob")).rejects.toMatchObject({ status: 404 });
});
it("deduplicates actions and rejects stale revisions", async () => {
  const app = await createMiniApp(env.handle.db, "user-alice", example());
  const input = { revision: 0, action: "save", key: crypto.randomUUID(), input: {}, state: { title: "First" } };
  expect(await runMiniAction(env.handle.db, app.id, "user-alice", input)).toEqual(await runMiniAction(env.handle.db, app.id, "user-alice", input));
  const rows = await queryMiniRecords(env.handle.db, app.id, "user-alice", app.document.queries.tasks); expect(rows.items).toHaveLength(1);
  await expect(runMiniAction(env.handle.db, app.id, "user-alice", { ...input, state: { title: "Other" } })).rejects.toMatchObject({ code: "MINI_IDEMPOTENCY_CONFLICT" });
  await mutateMiniRecord(env.handle.db, app.id, "user-alice", "tasks", "update", { id: rows.items[0].id, revision: 0, data: { title: "Second" } });
  await expect(mutateMiniRecord(env.handle.db, app.id, "user-alice", "tasks", "delete", { id: rows.items[0].id, revision: 0 })).rejects.toMatchObject({ code: "MINI_RECORD_CONFLICT" });
  await updateMiniApp(env.handle.db, app.id, "user-alice", { ...app.document, title: "Edited" }, 0);
  await expect(runMiniAction(env.handle.db, app.id, "user-alice", { ...input, key: crypto.randomUUID() })).rejects.toMatchObject({ code: "MINI_REVISION_CONFLICT" });
});
it("restores definitions without records and refuses incompatible populated schemas", async () => {
  const app = await createMiniApp(env.handle.db, "user-alice", example(), "agent");
  await mutateMiniRecord(env.handle.db, app.id, "user-alice", "tasks", "create", { data: { title: "Keep" } });
  const incompatible = example(); incompatible.tables.tasks.scope = "shared";
  await expect(updateMiniApp(env.handle.db, app.id, "user-alice", incompatible, 0)).rejects.toMatchObject({ code: "MINI_SCHEMA_MIGRATION_REQUIRED" });
  await updateMiniApp(env.handle.db, app.id, "user-alice", { ...example(), title: "Changed" }, 0, "chat");
  expect((await listVersions(env.handle.db, "user-alice", app.id)).items).toHaveLength(2);
  const restored = await restoreVersion(env.handle.db, "user-alice", app.id, 1);
  expect(restored.miniApp?.document.title).toBe(example().title);
  expect((await queryMiniRecords(env.handle.db, app.id, "user-alice", app.document.queries.tasks)).items).toHaveLength(1);
});
it("uses isolated fixtures for preview", async () => {
  const result = await previewMiniAction(example(), { action: "save", state: { title: "Preview" }, input: {} });
  expect(result.records.tasks).toHaveLength(1); expect(await env.handle.db.select().from(miniAppRecords)).toHaveLength(0);
});
it("encrypts with authenticated ownership and supports key rotation", () => {
  const ciphertext = seal({ apiKey: "top-secret" }, "alice"); expect(ciphertext).not.toContain("top-secret");
  expect(unseal(ciphertext, "alice")).toEqual({ apiKey: "top-secret" }); expect(() => unseal(ciphertext, "bob")).toThrow();
  vi.stubEnv("MINI_APP_SECRET_KEYS", JSON.stringify({ v1: Buffer.alloc(32, 7).toString("base64"), v2: Buffer.alloc(32, 8).toString("base64") })); vi.stubEnv("MINI_APP_ACTIVE_SECRET_KEY", "v2");
  expect(JSON.parse(seal(unseal(ciphertext, "alice"), "alice")).key).toBe("v2");
});
it("enforces shared connection grants, redacts keys and invalidates changed connectors", async () => {
  const app = await createMiniApp(env.handle.db, "user-alice", miniAppDocumentSchema.parse({ ...example(), connectors: { example: connector } }));
  await env.handle.db.insert(miniAppMembers).values({ appId: app.id, email: "bob@example.com", permissions: {} });
  const connection = await connectMiniApp(env.handle.db, app.id, "user-alice", { connector: "example", shared: true, apiKey: "very-secret-key" });
  setMiniTransportForTests(async () => ({ status: 200, body: '{"echo":"very-secret-key"}' }));
  await expect(callMiniConnector(env.handle.db, app.id, "user-bob", "example", "list", {})).rejects.toMatchObject({ code: "MINI_RECONNECT_REQUIRED" });
  await grantMiniConnection(env.handle.db, app.id, "user-alice", ("id" in connection ? connection.id : ""), "bob@example.com", ["list"]);
  expect(await callMiniConnector(env.handle.db, app.id, "user-bob", "example", "list", {})).toEqual({ echo: "[redacted]" });
  expect((await env.handle.db.select().from(miniAppConnections))[0].secret).not.toContain("very-secret-key");
  const changed = structuredClone(app.document); changed.connectors.example.operations.list.path = "/other";
  await updateMiniApp(env.handle.db, app.id, "user-alice", changed, 0);
  await expect(callMiniConnector(env.handle.db, app.id, "user-bob", "example", "list", {})).rejects.toMatchObject({ code: "MINI_RECONNECT_REQUIRED" });
  delete changed.connectors.example;
  await updateMiniApp(env.handle.db, app.id, "user-alice", changed, 1);
  const { listConnections } = await import("@/lib/mini-app/connections");
  expect((await listConnections(env.handle.db, app.id, "user-alice")).items[0].status).toBe("reauthorize");
  await env.handle.db.delete(summaries).where(eq(summaries.id, app.id)); expect(await env.handle.db.select().from(miniAppConnections)).toHaveLength(0);
});
it("calls public connectors without a connection or credential headers", async () => {
  const app = await createMiniApp(env.handle.db, "user-alice", miniAppDocumentSchema.parse({ ...example(), connectors: { example: { ...connector, auth: { type: "none" } } } }));
  const transport = vi.fn<BrokerTransport>(async () => ({ status: 200, body: '{"ok":true}' })); setMiniTransportForTests(transport);
  expect(await callMiniConnector(env.handle.db, app.id, "user-alice", "example", "list", {})).toEqual({ ok: true });
  expect(transport.mock.calls[0][2]).toEqual({ accept: "application/json" });
  await expect(connectMiniApp(env.handle.db, app.id, "user-alice", { connector: "example", apiKey: "unused" })).rejects.toMatchObject({ code: "MINI_CONNECTION_NOT_REQUIRED" });
  await expect(callMiniConnector(env.handle.db, app.id, "user-bob", "example", "list", {})).rejects.toBeTruthy();
  expect(transport).toHaveBeenCalledTimes(1);
});
it("binds OAuth callbacks, exchanges codes once with PKCE and handles cancellation", async () => {
  const doc = miniAppDocumentSchema.parse({ ...example(), connectors: { example: { ...connector, auth: { type: "oauth2", authorizationUrl: "https://auth.example.com/authorize", tokenUrl: "https://auth.example.com/token", clientId: "client", scopes: ["read"] } } } });
  const app = await createMiniApp(env.handle.db, "user-alice", doc);
  const transport = vi.fn(async () => ({ status: 200, body: '{"access_token":"oauth-token","refresh_token":"refresh-token","expires_in":3600}' })); setMiniTransportForTests(transport);
  const start = await connectMiniApp(env.handle.db, app.id, "user-alice", { connector: "example" }); const url = new URL(("authorizationUrl" in start ? start.authorizationUrl : ""));
  expect(url.searchParams.get("code_challenge_method")).toBe("S256");
  const p = new URLSearchParams({ state: url.searchParams.get("state")!, code: "code" });
  await expect(finishMiniOAuth(env.handle.db, app.id, "wrong", p)).rejects.toMatchObject({ code: "MINI_OAUTH_STATE" });
  await finishMiniOAuth(env.handle.db, app.id, "example", p); expect(transport).toHaveBeenCalledOnce();
  await expect(finishMiniOAuth(env.handle.db, app.id, "example", p)).rejects.toMatchObject({ code: "MINI_OAUTH_STATE" });
  const next = await connectMiniApp(env.handle.db, app.id, "user-alice", { connector: "example" });
  expect(await finishMiniOAuth(env.handle.db, app.id, "example", new URLSearchParams({ state: new URL(("authorizationUrl" in next ? next.authorizationUrl : "")).searchParams.get("state")!, error: "access_denied" }))).toEqual({ status: "cancelled" });
});
it("blocks private HTTP endpoints and anonymous creation", async () => {
  await expect(brokerRequest(new URL("https://127.0.0.1/"), "GET", {})).rejects.toMatchObject({ code: "URL_NOT_ALLOWED" });
  expect((await miniRoute.POST(apiRequest("POST", "mini-apps", { body: example() }))).status).toBe(401);
});
it("supports MCP authoring and read/write scope declarations", async () => {
  const keyResponse = await keysRoute.POST(apiRequest("POST", "keys", { token: env.tokens.alice, body: { name: "Test agent" } })); const { key } = await keyResponse.json(); let rpcId = 0;
  async function call(name: string, args: object) {
    const r = await mcpRoute.POST(apiRequest("POST", "/api/mcp", { token: key, headers: { accept: "application/json, text/event-stream" }, body: { jsonrpc: "2.0", id: ++rpcId, method: "tools/call", params: { name, arguments: args } } })); return (await r.json()).result;
  }
  expect((await call("get_mini_app_catalog", {})).structuredContent.schemaVersion).toBe(1);
  const created = await call("create_mini_app", { document: example() }); expect(created.isError).not.toBe(true); const id = created.structuredContent.app.id;
  expect((await call("get_mini_app", { appId: id })).structuredContent.app.revision).toBe(0);
  const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, id));
  expect(row.ogImageKey).toBeTruthy(); expect(row.imageStyle).toBe("illustration");
  const legacy = await createMiniApp(env.handle.db, "user-alice", example());
  const regenerated = await call("regenerate_mini_app_cover", { appId: legacy.id }); expect(regenerated.isError).not.toBe(true);
  const [redrawn] = await env.handle.db.select().from(summaries).where(eq(summaries.id, legacy.id));
  expect(redrawn.ogImageKey).toBeTruthy(); expect(redrawn.ogHeadline).toBeTruthy(); expect(redrawn.keywords).toContain("tasks");
  expect((await call("validate_mini_app", { document: example() })).structuredContent.ok).toBe(true);
  expect((await call("update_mini_app", { appId: id, revision: 0, document: { ...example(), title: "From MCP" } })).structuredContent.app.revision).toBe(1);
  expect((await call("list_mini_apps", {})).structuredContent.items).toHaveLength(2);
  expect(toolScope("get_mini_app")).toBe("chippy:read"); expect(toolScope("create_mini_app")).toBe("chippy:write");
});
it("runs pure JavaScript without host capabilities and rejects syntax errors", async () => {
  expect(await runMiniScript("return input.a + input.b", { a: 2, b: 3 })).toBe(5);
  expect(await runMiniScript("return [typeof process, typeof fetch, typeof require]")).toEqual(["undefined", "undefined", "undefined"]);
  await expect(runMiniScript("return (", null, true)).rejects.toMatchObject({ code: "MINI_SCRIPT_ERROR" });
});
it("terminates infinite scripts", async () => { await expect(runMiniScript("while(true) {}", null)).rejects.toMatchObject({ code: "MINI_SCRIPT_ERROR" }); });
it("validates all acceptance fixtures without live data or API calls", async () => {
  const { readFile } = await import("node:fs/promises");
  const transport = vi.fn(); setMiniTransportForTests(transport);
  for (const name of ["personal-tracker", "shared-checklist", "api-dashboard", "bitcoin-price", "weather"]) {
    const document = JSON.parse(await readFile(`../docs/mini-app-examples/${name}.json`, "utf8"));
    expect(await validateMiniApp(document)).toMatchObject({ ok: true, issues: [] });
  }
  expect(transport).not.toHaveBeenCalled(); expect(await env.handle.db.select().from(miniAppRecords)).toHaveLength(0);
  const invalid = example(); invalid.fixtures.tests = [{ action: "open", state: {}, input: {}, expectState: { title: "wrong" } }];
  expect((await validateMiniApp(invalid)).issues.join()).toContain("did not match");
});
it("caps listings at ten, deduplicates direct edits and blocks stale replay after permission changes", async () => {
  const { listMiniApps, mutateMiniRecordOnce } = await import("@/lib/mini-app/service");
  for (let i = 0; i < 12; i++) await createMiniApp(env.handle.db, "user-alice", example());
  const page = await listMiniApps(env.handle.db, "user-alice"); expect(page.items).toHaveLength(10);
  expect((await listMiniApps(env.handle.db, "user-alice", page.nextCursor!)).items).toHaveLength(2);
  const doc = example(); doc.tables.tasks.scope = "shared";
  const app = await createMiniApp(env.handle.db, "user-alice", doc);
  const edit = { key: crypto.randomUUID(), table: "tasks", operation: "create" as const, data: { title: "one" } };
  expect(await mutateMiniRecordOnce(env.handle.db, app.id, "user-alice", edit)).toEqual(await mutateMiniRecordOnce(env.handle.db, app.id, "user-alice", edit));
  await env.handle.db.insert(miniAppMembers).values({ appId: app.id, email: "bob@example.com", permissions: { tasks: "read" } });
  const read = { revision: 0, key: crypto.randomUUID(), action: "load", input: {}, state: { search: "" } };
  expect(await runMiniAction(env.handle.db, app.id, "user-bob", read)).toHaveProperty("state.records.items");
  await env.handle.db.update(miniAppMembers).set({ permissions: {} }).where(eq(miniAppMembers.appId, app.id));
  await expect(runMiniAction(env.handle.db, app.id, "user-bob", read)).rejects.toMatchObject({ code: "MINI_IDEMPOTENCY_CONFLICT" });
});
it("never retries uncertain external writes", async () => {
  const doc = miniAppDocumentSchema.parse({ ...example(), connectors: { example: { ...connector, operations: { write: { method: "POST", path: "/items" } } } }, actions: { write: { trigger: "interaction", steps: [{ type: "request", connector: "example", operation: "write", input: {}, into: "response" }] } }, ui: { root: "root", elements: { root: { type: "Button", props: { title: "Send" }, events: { press: "write" } } } } });
  const app = await createMiniApp(env.handle.db, "user-alice", doc);
  await connectMiniApp(env.handle.db, app.id, "user-alice", { connector: "example", apiKey: "write-key" });
  const transport = vi.fn(async () => { throw new Error("lost response"); }); setMiniTransportForTests(transport);
  const input = { revision: 0, key: crypto.randomUUID(), action: "write", input: {}, state: {} };
  await expect(runMiniAction(env.handle.db, app.id, "user-alice", input)).rejects.toMatchObject({ code: "MINI_EXTERNAL_OUTCOME_UNCERTAIN" });
  await expect(runMiniAction(env.handle.db, app.id, "user-alice", input)).rejects.toMatchObject({ code: "MINI_ACTION_ALREADY_STARTED" });
  expect(transport).toHaveBeenCalledOnce();
});
it("rejects expired OAuth state and prevents concurrent refresh token rotation", async () => {
  const { miniAppOAuth } = await import("@/lib/db/schema");
  const doc = miniAppDocumentSchema.parse({ ...example(), connectors: { example: { ...connector, auth: { type: "oauth2", authorizationUrl: "https://auth.example.com/authorize", tokenUrl: "https://auth.example.com/token", clientId: "client", scopes: [] } } } });
  const app = await createMiniApp(env.handle.db, "user-alice", doc);
  const pending = await connectMiniApp(env.handle.db, app.id, "user-alice", { connector: "example" });
  await env.handle.db.update(miniAppOAuth).set({ expiresAt: 0 });
  await expect(finishMiniOAuth(env.handle.db, app.id, "example", new URLSearchParams({ state: new URL("authorizationUrl" in pending ? pending.authorizationUrl : "").searchParams.get("state")!, code: "old" }))).rejects.toMatchObject({ code: "MINI_OAUTH_STATE" });
  const active = await connectMiniApp(env.handle.db, app.id, "user-alice", { connector: "example" });
  setMiniTransportForTests(async () => ({ status: 200, body: '{"access_token":"old-token","refresh_token":"rotating","expires_in":1}' }));
  await finishMiniOAuth(env.handle.db, app.id, "example", new URLSearchParams({ state: new URL("authorizationUrl" in active ? active.authorizationUrl : "").searchParams.get("state")!, code: "new" }));
  let release!: () => void; let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; }); const blocked = new Promise<void>(resolve => { release = resolve; });
  const transport = vi.fn(async (url: URL) => {
    if (url.pathname === "/token") { entered(); await blocked; return { status: 200, body: '{"access_token":"new-token","refresh_token":"rotated","expires_in":3600}' }; }
    return { status: 200, body: '{"ok":true}' };
  }); setMiniTransportForTests(transport);
  const first = callMiniConnector(env.handle.db, app.id, "user-alice", "example", "list", {}); await started;
  await expect(callMiniConnector(env.handle.db, app.id, "user-alice", "example", "list", {})).rejects.toMatchObject({ code: "MINI_REFRESH_BUSY" });
  release(); expect(await first).toEqual({ ok: true });
  expect(transport.mock.calls.filter(([url]) => url.pathname === "/token")).toHaveLength(1);
});
it("contains memory exhaustion and rejects exponential renderer graphs", async () => {
  await expect(runMiniScript("const a=[]; while(true) a.push(new Array(100000).fill(1));", null)).rejects.toMatchObject({ code: "MINI_SCRIPT_ERROR" });
  const doc = example(); doc.ui.elements.root.children = Array(100).fill("add"); doc.ui.elements.add.children = Array(100).fill("field");
  expect((await validateMiniApp(doc)).issues.join()).toContain("5000");
});
it("fences concurrent schema changes against record creation", async () => {
  const app = await createMiniApp(env.handle.db, "user-alice", example());
  const changed = example(); changed.tables.tasks.scope = "shared";
  const outcomes = await Promise.allSettled([
    updateMiniApp(env.handle.db, app.id, "user-alice", changed, 0),
    mutateMiniRecord(env.handle.db, app.id, "user-alice", "tasks", "create", { data: { title: "Concurrent" } }),
  ]);
  expect(outcomes.filter(o => o.status === "fulfilled")).toHaveLength(1);
  const current = await getMiniApp(env.handle.db, app.id, "user-alice");
  const stored = await env.handle.db.select().from(miniAppRecords).where(eq(miniAppRecords.appId, app.id));
  expect(current.document.tables.tasks.scope === "personal" || stored.length === 0).toBe(true);
});
it("paginates filtered runtime queries and marks revoked credentials for reconnection", async () => {
  const doc = example(); doc.queries.tasks.limit = 1;
  doc.actions.more = { trigger: "read", input: {}, steps: [{ type: "query", query: "tasks", into: "records", cursor: { get: "state.cursor" } }] };
  doc.connectors.example = miniAppDocumentSchema.parse({ ...example(), connectors: { example: connector } }).connectors.example;
  const app = await createMiniApp(env.handle.db, "user-alice", doc);
  for (const title of ["Match A", "Match B", "Other"]) await mutateMiniRecord(env.handle.db, app.id, "user-alice", "tasks", "create", { data: { title } });
  const first = await queryMiniRecords(env.handle.db, app.id, "user-alice", doc.queries.tasks, { state: { search: "Match" } });
  expect(first.items).toHaveLength(1); expect(first.nextCursor).toBe("1");
  const result = await runMiniAction(env.handle.db, app.id, "user-alice", { revision: 0, action: "more", key: crypto.randomUUID(), input: {}, state: { search: "Match", cursor: first.nextCursor } });
  expect(result).toMatchObject({ state: { records: { items: [expect.objectContaining({ id: expect.any(String) })], nextCursor: null } } });
  await connectMiniApp(env.handle.db, app.id, "user-alice", { connector: "example", apiKey: "expired-key" });
  setMiniTransportForTests(async () => ({ status: 401, body: "credential rejected" }));
  await expect(callMiniConnector(env.handle.db, app.id, "user-alice", "example", "list", {})).rejects.toMatchObject({ code: "MINI_RECONNECT_REQUIRED" });
  expect((await env.handle.db.select().from(miniAppConnections))[0].status).toBe("reconnect");
});
it("runs a saved app's script step for actions executed on the device", async () => {
  const doc = example(); doc.scripts = { double: "return input.n * 2;" };
  const app = await createMiniApp(env.handle.db, "user-alice", doc);
  expect(await runMiniScriptStep(env.handle.db, app.id, "user-alice", { revision: 0, script: "double", input: { n: 21 } })).toEqual({ value: 42 });
  await expect(runMiniScriptStep(env.handle.db, app.id, "user-alice", { revision: 0, script: "missing", input: null })).rejects.toMatchObject({ code: "MINI_SCRIPT_NOT_FOUND" });
  await expect(runMiniScriptStep(env.handle.db, app.id, "user-alice", { revision: 5, script: "double", input: { n: 1 } })).rejects.toMatchObject({ code: "MINI_REVISION_CONFLICT" });
  await expect(runMiniScriptStep(env.handle.db, app.id, "user-bob", { revision: 0, script: "double", input: { n: 1 } })).rejects.toMatchObject({ status: 404 });
});
