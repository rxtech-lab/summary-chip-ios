import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as devices from "@/app/api/v1/devices/route";
import * as imports from "@/app/api/v1/summaries/import/route";
import * as summaries from "@/app/api/v1/summaries/route";
import { pushDevices, users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));

let env: TestEnv;
const device = { installationId: "f6daa60d-d123-47a2-8512-596ffb2a9872", token: "a".repeat(64), environment: "sandbox", platform: "ios" };
const body = { title: "Monarch migration", summary: "Butterflies fly south each autumn.", text: "Field notes about monarch butterflies migrating south." };
const register = (token = env.tokens.alice, overrides = {}) => devices.POST(apiRequest("POST", "/api/v1/devices", { token, body: { ...device, ...overrides } }));

beforeEach(async () => { env = await setupTestEnv(); sendPush.mockReset().mockResolvedValue({ status: 200 }); apnsConfigured.mockReset().mockReturnValue(true); });
afterEach(() => { env.teardown(); vi.restoreAllMocks(); });

describe("summary notifications", () => {
  it("registers only authenticated, valid devices", async () => {
    expect((await devices.POST(apiRequest("POST", "/api/v1/devices", { body: device }))).status).toBe(401);
    expect((await register(env.tokens.alice, { token: "invalid" })).status).toBe(400);
    expect((await register(env.tokens.alice, { environment: "invalid" })).status).toBe(400);
    expect((await register()).status).toBe(204);
  });

  it("notifies only the owner after an import is saved, including private summaries", async () => {
    await register();
    await register(env.tokens.bob, { token: "b".repeat(64), installationId: crypto.randomUUID() });
    const response = await imports.POST(apiRequest("POST", "/api/v1/summaries/import", { token: env.tokens.alice, body: { ...body, visibility: "private" } }));
    expect(response.status).toBe(201);
    const summary = await response.json();
    await vi.waitFor(() => expect(sendPush).toHaveBeenCalledTimes(1));
    expect(sendPush).toHaveBeenCalledWith(expect.objectContaining({ token: device.token, environment: "sandbox" }), expect.objectContaining({
      aps: { alert: { title: "Summary added", body: body.title }, sound: "default" },
      summaryId: summary.id, userId: "user-alice",
    }));
  });

  it("also notifies after API generation, once for each registered device", async () => {
    await register();
    await register(env.tokens.alice, { token: "c".repeat(64), installationId: crypto.randomUUID(), platform: "macos", environment: "production" });
    expect((await summaries.POST(apiRequest("POST", "/api/v1/summaries", { token: env.tokens.alice, body: { source: { type: "text", text: body.text } } }))).status).toBe(201);
    await vi.waitFor(() => expect(sendPush).toHaveBeenCalledTimes(2));
  });

  it("does not notify for failed imports", async () => {
    await register();
    expect((await imports.POST(apiRequest("POST", "/api/v1/summaries/import", { token: env.tokens.alice, body: { ...body, text: "" } }))).status).toBe(400);
    expect(sendPush).not.toHaveBeenCalled();
  });

  it("skips delivery when APNs is unconfigured", async () => {
    await register();
    apnsConfigured.mockReturnValue(false);
    expect((await imports.POST(apiRequest("POST", "/api/v1/summaries/import", { token: env.tokens.alice, body }))).status).toBe(201);
    expect(sendPush).not.toHaveBeenCalled();
  });

  it("removes registrations when an account is deleted", async () => {
    await register();
    await register(env.tokens.bob, { token: "b".repeat(64), installationId: crypto.randomUUID() });
    await env.handle.db.delete(users).where(eq(users.id, "user-alice"));
    expect(await env.handle.db.select().from(pushDevices)).toEqual([expect.objectContaining({ ownerId: "user-bob" })]);
  });

  it("replaces rotated tokens and moves a device to the current account", async () => {
    await register();
    await register(env.tokens.alice, { token: "c".repeat(64) });
    expect(await env.handle.db.select().from(pushDevices)).toHaveLength(1);
    await register(env.tokens.bob, { token: "c".repeat(64) });
    expect(await env.handle.db.select().from(pushDevices)).toEqual([expect.objectContaining({ ownerId: "user-bob", token: "c".repeat(64) })]);
    expect((await devices.DELETE(apiRequest("DELETE", "/api/v1/devices", { token: env.tokens.alice, body: { installationId: device.installationId } }))).status).toBe(204);
    expect(await env.handle.db.select().from(pushDevices)).toHaveLength(1);
    await devices.DELETE(apiRequest("DELETE", "/api/v1/devices", { token: env.tokens.bob, body: { installationId: device.installationId } }));
    expect(await env.handle.db.select().from(pushDevices)).toHaveLength(0);
  });

  it("keeps a successful import successful when push delivery fails", async () => {
    await register();
    sendPush.mockRejectedValue(new Error("offline"));
    expect((await imports.POST(apiRequest("POST", "/api/v1/summaries/import", { token: env.tokens.alice, body }))).status).toBe(201);
    await vi.waitFor(() => expect(sendPush).toHaveBeenCalledTimes(1));
    expect(await env.handle.db.select().from(pushDevices)).toHaveLength(1);
  });

  it("removes invalid APNs tokens but keeps tokens on transient errors", async () => {
    await register();
    await register(env.tokens.alice, { token: "c".repeat(64), installationId: crypto.randomUUID() });
    sendPush.mockImplementation(async (target: { token: string }) => target.token === device.token ? { status: 410, reason: "Unregistered" } : { status: 503, reason: "ServiceUnavailable" });
    await imports.POST(apiRequest("POST", "/api/v1/summaries/import", { token: env.tokens.alice, body }));
    await vi.waitFor(async () => expect(await env.handle.db.select().from(pushDevices)).toEqual([expect.objectContaining({ token: "c".repeat(64) })]));
  });
});
