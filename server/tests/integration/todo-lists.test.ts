import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import * as lists from "@/app/api/v1/todo-lists/route";
import * as list from "@/app/api/v1/todo-lists/[id]/route";
import * as devices from "@/app/api/v1/devices/route";
import * as uploadsRoute from "@/app/api/v1/uploads/route";
import * as images from "@/app/api/v1/document-images/route";
import * as mcp from "@/app/api/mcp/route";
import * as keys from "@/app/api/v1/api-keys/route";
import { summaries, summaryTranslations, todoLists, todoNotifications, todoNotificationDeliveries, documentVersions } from "@/lib/db/schema";
import type { TodoDocument } from "@/lib/contracts/todo";
import { deliverTodoNotifications } from "@/lib/services/todo-notifications";
import { toolScope } from "@/lib/mcp/oauth-config";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));
let env: TestEnv;
const deadline = "2030-01-01T10:00:00+08:00";
const document: TodoDocument = { title: "工作", description: "## Plan\n\n**Research** ![Photo](https://example.com/a.webp)", deadline,
  items: [{ id: "one", title: "Search investors", deadline, completed: false }, { id: "two", title: "Done already", deadline, completed: true }] };
const due = new Date("2030-01-01T02:00:01Z");
beforeEach(async () => {
  env = await setupTestEnv(); sendPush.mockReset().mockResolvedValue({ status: 200 }); apnsConfigured.mockReset().mockReturnValue(true);
});
afterEach(() => env.teardown());
async function create(doc = document) {
  const response = await lists.POST(apiRequest("POST", "/api/v1/todo-lists", { token: env.tokens.alice, body: { document: doc } }));
  expect(response.status).toBe(201);
  return (await response.json()).todoList as { id: string; revision: number; document: TodoDocument };
}
async function update(id: string, doc: TodoDocument, revision = 0, token = env.tokens.alice) {
  return list.PUT(apiRequest("PUT", `/api/v1/todo-lists/${id}`, { token, body: { document: doc, revision } }), params({ id }));
}
async function register(owner = "alice", installationId = crypto.randomUUID()) {
  await devices.POST(apiRequest("POST", "/api/v1/devices", { token: env.tokens[owner as "alice" | "bob"], body: {
    installationId, token: installationId.replaceAll("-", "").padEnd(64, "a"), environment: "sandbox", platform: "ios",
  } }));
  return installationId;
}

describe("todo lists", () => {
  it("creates a private chip with checklist progress and per-item deadlines", async () => {
    const created = await create();
    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, created.id));
    expect(row).toMatchObject({ kind: "todo_list", title: document.title, visibility: "private", expiresAt: null });
    expect(row.summary).toContain("1/2 completed");
    expect(row.highlights).toEqual([`☐ Search investors · ${deadline}`]);
    const response = await lists.GET(apiRequest("GET", "/api/v1/todo-lists", { token: env.tokens.alice }));
    expect((await response.json()).todoLists[0]).toMatchObject({ id: created.id, revision: 0, document });
    expect(await env.handle.db.select().from(todoNotifications)).toHaveLength(2);
    expect(sendPush).not.toHaveBeenCalled();
  });
  it("requires authentication, denies private reads and refuses other users' edits/deletes", async () => {
    expect((await lists.POST(apiRequest("POST", "/api/v1/todo-lists", { body: { document } }))).status).toBe(401);
    const { id } = await create();
    expect((await list.GET(apiRequest("GET", `/api/v1/todo-lists/${id}`, { token: env.tokens.bob }), params({ id }))).status).toBe(404);
    expect((await update(id, document, 0, env.tokens.bob)).status).toBe(404);
    expect((await list.DELETE(apiRequest("DELETE", `/api/v1/todo-lists/${id}`, { token: env.tokens.bob }), params({ id }))).status).toBe(404);
  });
  it.each([
    { ...document, deadline: "2030-01-01" },
    { ...document, items: [{ ...document.items[0], deadline: "2030-01-01T10:00:00" }] },
    { ...document, items: [document.items[0], document.items[0]] },
    { ...document, title: " " },
    { ...document, items: [{ title: "missing fields" }] },
  ])("rejects malformed documents %#", async (doc) => {
    expect((await lists.POST(apiRequest("POST", "/api/v1/todo-lists", { token: env.tokens.alice, body: { document: doc } }))).status).toBe(400);
  });
  it("saves Markdown and completion, and refuses stale changes without touching chip or history", async () => {
    const { id } = await create();
    await env.handle.db.insert(summaryTranslations).values({ summaryId: id, language: "zh-Hans", title: "待办", summary: "旧进度", highlights: [], createdAt: new Date(), updatedAt: new Date() });
    const changed = { ...document, title: "Updated", description: "![New](https://example.com/new.webp)", items: document.items.map((item) => ({ ...item, completed: true })) };
    expect((await update(id, changed)).status).toBe(200);
    expect((await update(id, document)).status).toBe(409);
    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, id));
    expect(row).toMatchObject({ title: "Updated", summary: expect.stringContaining("2/2 completed"), contentMarkdown: changed.description });
    expect(await env.handle.db.select().from(documentVersions).where(eq(documentVersions.summaryId, id))).toHaveLength(2);
    expect(await env.handle.db.select().from(summaryTranslations).where(eq(summaryTranslations.summaryId, id))).toHaveLength(0);
  });
  it("delivers overdue list and incomplete item exactly once, only to the owner", async () => {
    await register(); await register("bob"); await create();
    await deliverTodoNotifications(env.handle.db, new Date("2030-01-01T01:59:59Z"));
    expect(sendPush).not.toHaveBeenCalled();
    await deliverTodoNotifications(env.handle.db, due);
    expect(sendPush).toHaveBeenCalledTimes(2);
    expect(sendPush.mock.calls.every((call) => call[1].userId === "user-alice")).toBe(true);
    expect(sendPush.mock.calls.some((call) => call[1].aps.alert.body.includes("Done already"))).toBe(false);
    await deliverTodoNotifications(env.handle.db, due);
    expect(sendPush).toHaveBeenCalledTimes(2);
  });
  it("suppresses completed, deleted and rescheduled item deadlines", async () => {
    await register(); const { id } = await create();
    const changed = { ...document, deadline: "2030-02-01T00:00:00Z", items: [{ ...document.items[0], deadline: "2030-02-01T00:00:00Z", completed: true }] };
    await update(id, changed);
    await deliverTodoNotifications(env.handle.db, due);
    expect(sendPush).not.toHaveBeenCalled();
    await list.DELETE(apiRequest("DELETE", `/api/v1/todo-lists/${id}`, { token: env.tokens.alice }), params({ id }));
    expect(await env.handle.db.select().from(todoLists)).toHaveLength(0);
    expect(await env.handle.db.select().from(todoNotifications)).toHaveLength(0);
  });
  it("retries transient failures without resending accepted installations", async () => {
    const accepted = await register(); await register("alice"); await create();
    sendPush.mockImplementation(async (device) => ({ status: device.installationId === accepted ? 200 : 503 }));
    await deliverTodoNotifications(env.handle.db, due);
    expect(await env.handle.db.select().from(todoNotificationDeliveries)).toHaveLength(2);
    sendPush.mockClear().mockResolvedValue({ status: 200 });
    await deliverTodoNotifications(env.handle.db, due);
    expect(sendPush).toHaveBeenCalledTimes(2);
    expect(sendPush.mock.calls.every((call) => call[0].installationId !== accepted)).toBe(true);
  });
  it("keeps events queued when APNs is not configured and claims concurrent sweeps only once", async () => {
    await register(); await create(); apnsConfigured.mockReturnValue(false);
    await deliverTodoNotifications(env.handle.db, due); expect(sendPush).not.toHaveBeenCalled();
    apnsConfigured.mockReturnValue(true);
    await Promise.all([deliverTodoNotifications(env.handle.db, due), deliverTodoNotifications(env.handle.db, due)]);
    expect(sendPush).toHaveBeenCalledTimes(2);
  });
  it("creates via MCP and notifies the owner, with read/write scopes", async () => {
    await register();
    const key = (await (await keys.POST(apiRequest("POST", "/api/v1/api-keys", { token: env.tokens.alice, body: { name: "Todo agent" } }))).json()).key;
    const response = await mcp.POST(apiRequest("POST", "/api/mcp", { token: key, headers: { accept: "application/json, text/event-stream" }, body: {
      jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "create_todo_list", arguments: { document } },
    } }));
    const rpc = await response.json();
    expect(rpc.result.isError).not.toBe(true);
    await vi.waitFor(() => expect(sendPush).toHaveBeenCalledTimes(1));
    expect(sendPush.mock.calls[0][1].aps.alert.title).toBe("AI created a todo list");
    expect(toolScope("get_todo_list")).toBe("chippy:read");
    expect(toolScope("list_todo_lists")).toBe("chippy:read");
    expect(toolScope("create_todo_list")).toBe("chippy:write");
  });
  it("finalizes only owned, complete image uploads as bounded WebP", async () => {
    const data = await sharp({ create: { width: 2500, height: 1000, channels: 4, background: "#f00" } }).png().toBuffer();
    const ticket = await (await uploadsRoute.POST(apiRequest("POST", "/api/v1/uploads", { token: env.tokens.alice,
      body: { filename: "photo.png", mimeType: "image/png", byteSize: data.byteLength } }))).json();
    const finalize = (token = env.tokens.alice) => images.POST(apiRequest("POST", "/api/v1/document-images", { token, body: { uploadKey: ticket.key } }));
    expect((await finalize(env.tokens.bob)).status).toBe(403);
    expect((await finalize()).status).toBe(409);
    await env.store.put(ticket.key, { bytes: data, contentType: "image/png" });
    const response = await finalize(); expect(response.status).toBe(200);
    const { image } = await response.json();
    expect(image).toMatchObject({ width: 2048, height: 819 });
    expect(image.url).toMatch(/\.webp$/);
    const file = image.url.split("/").at(-1);
    const stored = await env.store.get(`document-images/${file}`);
    const metadata = await sharp(stored.bytes).metadata();
    expect(metadata.format).toBe("webp"); expect(metadata.exif).toBeUndefined();
  });
});
