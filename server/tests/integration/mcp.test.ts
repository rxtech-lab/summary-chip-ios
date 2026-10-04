import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as apiKeysRoute from "@/app/api/v1/api-keys/route";
import * as apiKeyRoute from "@/app/api/v1/api-keys/[id]/route";
import * as mcpRoute from "@/app/api/mcp/route";
import { apiKeys } from "@/lib/db/schema";
import { hashApiKey, MAX_API_KEYS_PER_USER } from "@/lib/services/api-keys";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
});

afterEach(() => {
  env.teardown();
});

async function createKey(name = "Claude Code", token = env.tokens.alice) {
  const response = await apiKeysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token, body: { name } }));
  expect(response.status).toBe(201);
  return response.json() as Promise<{ key: string; apiKey: { id: string; name: string; hint: string } }>;
}

let rpcId = 0;

function mcpRequest(key: string | undefined, method: string, rpcParams?: unknown) {
  return mcpRoute.POST(apiRequest("POST", "/api/mcp", {
    token: key,
    headers: { accept: "application/json, text/event-stream" },
    body: { jsonrpc: "2.0", id: ++rpcId, method, ...(rpcParams === undefined ? {} : { params: rpcParams }) },
  }));
}

async function callTool(key: string, name: string, args: Record<string, unknown>) {
  const response = await mcpRequest(key, "tools/call", { name, arguments: args });
  expect(response.status).toBe(200);
  const body = await response.json();
  return body.result as { isError?: boolean; content: { type: string; text: string }[]; structuredContent?: Record<string, unknown> };
}

const CHIP = {
  title: "Monarch migration",
  summary: "Monarch butterflies fly thousands of kilometres south every autumn.",
  text: "Raw field notes: monarchs left the meadow on 2 October, heading south-west.",
  keyPoints: ["They fly south"],
  tags: ["Butterflies", "migration"],
  category: "Science",
};

describe("/api/v1/api-keys", () => {
  it("needs the app's OAuth token, not an API key", async () => {
    const { key } = await createKey();
    const response = await apiKeysRoute.GET(apiRequest("GET", "/api/v1/api-keys", { token: key }));
    expect(response.status).toBe(401);
  });

  it("returns the key once and stores only its hash", async () => {
    const created = await createKey("  Claude Code  ");
    expect(created.key).toMatch(/^chippy_[A-Za-z0-9_-]{43}$/);
    expect(created.apiKey).toMatchObject({ name: "Claude Code", toolCallCount: 0, summariesAddedCount: 0, lastUsedAt: null });
    expect(created.apiKey.hint).toBe(`${created.key.slice(0, 11)}…${created.key.slice(-4)}`);

    const [row] = await env.handle.db.select().from(apiKeys);
    expect(row.keyHash).toBe(hashApiKey(created.key));
    expect(JSON.stringify(row)).not.toContain(created.key);

    const list = await (await apiKeysRoute.GET(apiRequest("GET", "/api/v1/api-keys", { token: env.tokens.alice }))).json();
    expect(list.items).toHaveLength(1);
    expect(list.items[0]).toEqual(created.apiKey);
    expect(JSON.stringify(list)).not.toContain(created.key);
  });

  it("validates the name", async () => {
    for (const body of [{ name: " " }, { name: "x".repeat(61) }, { name: "ok", extra: 1 }]) {
      const response = await apiKeysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token: env.tokens.alice, body }));
      expect(response.status).toBe(400);
    }
  });

  it("renames and revokes only the owner's keys", async () => {
    const { key, apiKey } = await createKey();
    const bobRename = await apiKeyRoute.PATCH(apiRequest("PATCH", `/api/v1/api-keys/${apiKey.id}`, { token: env.tokens.bob, body: { name: "Mine" } }), params({ id: apiKey.id }));
    expect(bobRename.status).toBe(404);
    const bobRevoke = await apiKeyRoute.DELETE(apiRequest("DELETE", `/api/v1/api-keys/${apiKey.id}`, { token: env.tokens.bob }), params({ id: apiKey.id }));
    expect(bobRevoke.status).toBe(404);

    const renamed = await apiKeyRoute.PATCH(apiRequest("PATCH", `/api/v1/api-keys/${apiKey.id}`, { token: env.tokens.alice, body: { name: "Cursor" } }), params({ id: apiKey.id }));
    expect(renamed.status).toBe(200);
    expect((await renamed.json()).name).toBe("Cursor");

    expect((await mcpRequest(key, "tools/list")).status).toBe(200);
    const revoked = await apiKeyRoute.DELETE(apiRequest("DELETE", `/api/v1/api-keys/${apiKey.id}`, { token: env.tokens.alice }), params({ id: apiKey.id }));
    expect(revoked.status).toBe(204);
    const after = await mcpRequest(key, "tools/list");
    expect(after.status).toBe(401);
    expect((await after.json()).error.code).toBe("INVALID_API_KEY");
  });

  it("caps the number of keys", async () => {
    // The first authenticated request creates the user row the keys belong to.
    await apiKeysRoute.GET(apiRequest("GET", "/api/v1/api-keys", { token: env.tokens.alice }));
    await env.handle.db.insert(apiKeys).values(Array.from({ length: MAX_API_KEYS_PER_USER }, (_, index) => ({
      id: `key-${index}`, ownerId: "user-alice", name: `Key ${index}`, keyHash: `hash-${index}`, hint: "chippy_…",
    })));
    const response = await apiKeysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token: env.tokens.alice, body: { name: "One more" } }));
    expect(response.status).toBe(409);
    expect((await response.json()).error.code).toBe("API_KEY_LIMIT_REACHED");
  });
});

describe("/api/mcp", () => {
  it("rejects requests without a valid API key", async () => {
    const missing = await mcpRequest(undefined, "tools/list");
    expect(missing.status).toBe(401);
    expect(missing.headers.get("www-authenticate")).toContain("Bearer");
    expect((await missing.json()).error.code).toBe("MISSING_API_KEY");
    expect((await mcpRequest("chippy_not-a-real-key", "tools/list")).status).toBe(401);
    // The app's OAuth token is not an API key.
    expect((await mcpRequest(env.tokens.alice, "tools/list")).status).toBe(401);
  });

  it("initializes and lists the three tools", async () => {
    const { key } = await createKey();
    const init = await mcpRequest(key, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
    expect(init.status).toBe(200);
    const initBody = await init.json();
    expect(initBody.result.serverInfo.name).toBe("chippy");
    expect(initBody.result.instructions).toContain("search_summaries");

    const list = await (await mcpRequest(key, "tools/list")).json();
    expect(list.result.tools.map((tool: { name: string }) => tool.name).sort()).toEqual(["add_summary", "list_summaries", "search_summaries"]);
    const add = list.result.tools.find((tool: { name: string }) => tool.name === "add_summary");
    expect(add.inputSchema.required).toEqual(expect.arrayContaining(["title", "summary", "text"]));
  });

  it("answers GET with 405 (stateless, no server stream)", async () => {
    expect((await mcpRoute.GET()).status).toBe(405);
  });

  it("adds a chip as the key's owner and counts the usage", async () => {
    const { key, apiKey } = await createKey();
    const result = await callTool(key, "add_summary", { ...CHIP, visibility: "private", ttlDays: "never" });
    expect(result.isError).toBeFalsy();
    expect(result.content[0].text).toContain("Added \"Monarch migration\" (private).");
    const summary = (result.structuredContent as { summary: Record<string, unknown> }).summary;
    expect(summary).toMatchObject({
      title: CHIP.title,
      keyPoints: ["They fly south"],
      tags: ["butterflies", "migration"],
      category: "Science",
      visibility: "private",
      isOwner: true,
      hasSourceText: true,
    });

    const [row] = await env.handle.db.select().from(apiKeys).where(eq(apiKeys.id, apiKey.id));
    expect(row).toMatchObject({ toolCallCount: 1, summariesAddedCount: 1 });
    expect(row.lastUsedAt).toBeInstanceOf(Date);

    // Bob's key doesn't see Alice's private chip.
    const bob = await createKey("Bob", env.tokens.bob);
    const bobList = await callTool(bob.key, "list_summaries", {});
    expect(bobList.structuredContent).toMatchObject({ count: 0, items: [], nextCursor: null });
  });

  it("reports a duplicate as a tool error naming the existing chip", async () => {
    const { key, apiKey } = await createKey();
    await callTool(key, "add_summary", CHIP);
    const result = await callTool(key, "add_summary", { ...CHIP, sourceUrl: undefined });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/^Not added: this chip is already in the library as "Monarch migration" \(https?:\/\/.+\)\. Reason: .+ allowDuplicate: true/);

    const again = await callTool(key, "add_summary", { ...CHIP, allowDuplicate: true });
    expect(again.isError).toBeFalsy();
    const [row] = await env.handle.db.select().from(apiKeys).where(eq(apiKeys.id, apiKey.id));
    expect(row).toMatchObject({ toolCallCount: 3, summariesAddedCount: 2 });
  });

  it("validates arguments with the import API's limits", async () => {
    const { key } = await createKey();
    const tooMany = await callTool(key, "add_summary", { ...CHIP, keyPoints: ["1", "2", "3", "4", "5", "6"] });
    expect(tooMany.isError).toBe(true);
    expect(tooMany.content[0].text).toMatch(/^Invalid keyPoints: /);
    const badTtl = await callTool(key, "add_summary", { ...CHIP, ttlDays: 5 });
    expect(badTtl.isError).toBe(true);
    const missing = await callTool(key, "add_summary", { title: "No text" });
    expect(missing.isError).toBe(true);
  });

  it("lists and searches the library with filters and cursors", async () => {
    const { key } = await createKey();
    await callTool(key, "add_summary", CHIP);
    await callTool(key, "add_summary", { title: "Rust ownership", summary: "Borrowing rules explained.", text: "The borrow checker enforces aliasing rules.", tags: ["rust"], category: "Technology", sourceUrl: "https://github.com/rust-lang/book" });

    const all = await callTool(key, "list_summaries", { limit: 1 });
    expect(all.structuredContent).toMatchObject({ count: 1, items: [{ title: "Rust ownership", source: "github" }] });
    const next = await callTool(key, "list_summaries", { limit: 1, cursor: (all.structuredContent as { nextCursor: string }).nextCursor });
    expect(next.structuredContent).toMatchObject({ count: 1, items: [{ title: "Monarch migration" }], nextCursor: null });

    const tagged = await callTool(key, "list_summaries", { tag: "Rust" });
    expect(tagged.structuredContent).toMatchObject({ count: 1, items: [{ title: "Rust ownership" }] });
    const science = await callTool(key, "list_summaries", { category: "Science", scope: "mine" });
    expect(science.structuredContent).toMatchObject({ count: 1, items: [{ title: "Monarch migration" }] });

    const search = await callTool(key, "search_summaries", { query: "butterflies", limit: 5 });
    expect(search.isError).toBeFalsy();
    expect((search.structuredContent as { items: { title: string }[] }).items[0].title).toBe("Monarch migration");

    const github = await callTool(key, "search_summaries", { query: "borrow checker", source: "github" });
    expect((github.structuredContent as { items: { title: string }[] }).items.map((item) => item.title)).toEqual(["Rust ownership"]);
  });
});
