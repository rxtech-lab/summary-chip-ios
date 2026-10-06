import { and, eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as tripRoute from "@/app/api/v1/trips/[id]/route";
import * as operationsRoute from "@/app/api/v1/trips/[id]/operations/route";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as viewsRoute from "@/app/api/v1/views/route";
import * as devicesRoute from "@/app/api/v1/devices/route";
import * as cronRoute from "@/app/api/cron/trip-notifications/route";
import { summaries, tripNotificationBatches as batches, tripNotificationDeliveries as deliveries, users } from "@/lib/db/schema";
import { applyChatOperations, type TripJson } from "@/lib/services/trips";
import { deliverTripNotification, planTripNotification, publishTripNotification, resumeTripNotifications, TRIP_NOTIFICATION_DELAY_MS, writeTripChangeSummary } from "@/lib/services/trip-notifications";
import { setTripNotifierForTests } from "@/lib/trips/notifier";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));
const document = {
  title: "Kyoto weekend", startDate: "2026-11-06", endDate: "2026-11-08", timeZone: "Asia/Tokyo", currency: "JPY",
  places: [], days: [], transports: [], hotels: [], expenses: [], notes: [], sources: [], views: [],
};
let env: TestEnv;
let trip: TripJson;
let started: string[];

beforeEach(async () => {
  env = await setupTestEnv();
  sendPush.mockReset().mockResolvedValue({ status: 200 });
  apnsConfigured.mockReset().mockReturnValue(true);
  started = [];
  setTripNotifierForTests({ start: async (id) => { started.push(id); } });
  const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", { token: env.tokens.alice, body: { document, visibility: "public" } }));
  expect(response.status).toBe(201);
  trip = (await response.json()).trip;
  for (const [token, char] of [[env.tokens.alice, "a"], [env.tokens.bob, "b"]]) {
    expect((await devicesRoute.POST(apiRequest("POST", "/api/v1/devices", { token,
      body: { installationId: crypto.randomUUID(), token: char.repeat(64), environment: "sandbox", platform: "ios" },
    }))).status).toBe(204);
  }
});
afterEach(() => { env.teardown(); vi.unstubAllEnvs(); });

async function edit(title: string, now?: Date) {
  const response = await operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${trip.id}/operations`, {
    token: env.tokens.alice, body: { operations: [{ op: "set_meta", meta: { title } }] },
  }), params({ id: trip.id }));
  expect(response.status).toBe(200);
  const [batch] = await env.handle.db.select().from(batches).where(and(eq(batches.tripId, trip.id), eq(batches.status, "pending")));
  if (now) await env.handle.db.update(batches).set({ dueAt: now }).where(eq(batches.id, batch.id));
  return { ...batch, ...(now ? { dueAt: now } : {}) };
}
async function openShared() {
  expect((await viewsRoute.POST(apiRequest("POST", "/api/v1/views", { token: env.tokens.bob, body: { slug: trip.slug } }))).status).toBe(200);
}
async function prepare(batch: Awaited<ReturnType<typeof edit>>, runner = "runner") {
  const plan = await planTripNotification(env.handle.db, batch.id, runner, batch.dueAt);
  expect(plan.status).toBe("summarize");
  if (plan.status !== "summarize") throw new Error("Expected summary plan");
  const body = await writeTripChangeSummary(plan.input);
  expect(await publishTripNotification(env.handle.db, batch.id, runner, plan.revision, body)).toBe(true);
  return plan;
}

describe("debounced trip notifications", () => {
  it("groups operations, PUT and chat saves, restarts the quiet period, and summarizes final net changes", async () => {
    const first = await edit("Temporary title");
    const put = await tripRoute.PUT(apiRequest("PUT", `/api/v1/trips/${trip.id}`, { token: env.tokens.alice,
      body: { revision: 1, document: { ...trip.document, title: "Final trip" } },
    }), params({ id: trip.id }));
    expect(put.status).toBe(200);
    await applyChatOperations(env.handle.db, "user-alice", trip.id, [{ op: "set_meta", meta: { intro: "A new introduction" } }], { keepValid: true });
    const [batch] = await env.handle.db.select().from(batches);
    expect(batch).toMatchObject({ id: first.id, revision: 3, beforeDocument: { title: document.title }, afterDocument: { title: "Final trip", intro: "A new introduction" } });
    expect(batch.dueAt.getTime()).toBeGreaterThanOrEqual(first.dueAt.getTime());
    expect(await planTripNotification(env.handle.db, batch.id, "runner", new Date(batch.dueAt.getTime() - 1))).toEqual({ status: "wait", nextAt: batch.dueAt.getTime() });
    expect(batch.dueAt.getTime() - Date.now()).toBeGreaterThan(TRIP_NOTIFICATION_DELAY_MS - 10_000);
    const plan = await prepare(batch);
    expect(plan.input.changes).toEqual(expect.arrayContaining([
      { section: "title", before: document.title, after: "Final trip" },
      expect.objectContaining({ section: "intro", after: "A new introduction" }),
    ]));
    expect(JSON.stringify(plan.input)).not.toContain("Temporary title");
    expect(env.ai.calls.summarizeTripChanges).toHaveLength(1);
    await vi.waitFor(() => expect(started).toHaveLength(3));
    expect(new Set(started).size).toBe(1);
    expect(sendPush).not.toHaveBeenCalled();
  });

  it("notifies the creator and shared-link readers using each recipient's account in the payload", async () => {
    await openShared();
    const batch = await edit("New itinerary");
    await prepare(batch);
    expect(await deliverTripNotification(env.handle.db, batch.id, "runner")).toBe(true);
    expect(sendPush).toHaveBeenCalledTimes(2);
    expect(sendPush.mock.calls.map((call) => call[1].userId).sort()).toEqual(["user-alice", "user-bob"]);
    for (const call of sendPush.mock.calls) {
      expect(call[1]).toMatchObject({ summaryId: trip.id, tripId: trip.id, aps: { alert: { title: "Trip updated", body: "New itinerary: Updated title." } } });
      expect(call[2]).toEqual({ collapseId: `trip-update:${batch.id}` });
    }
    expect(await env.handle.db.select().from(batches)).toHaveLength(0);
    expect(await deliverTripNotification(env.handle.db, batch.id, "runner")).toBe(true);
    expect(sendPush).toHaveBeenCalledTimes(2);
  });

  it("keeps unviewed users out and rechecks sharing after the delay", async () => {
    const batch = await edit("New itinerary");
    await prepare(batch);
    await deliverTripNotification(env.handle.db, batch.id, "runner");
    expect(sendPush.mock.calls.map((call) => call[1].userId)).toEqual(["user-alice"]);
    sendPush.mockClear();
    await openShared();
    const next = await edit("Private itinerary");
    await prepare(next);
    await env.handle.db.update(summaries).set({ visibility: "private" }).where(eq(summaries.id, trip.id));
    await deliverTripNotification(env.handle.db, next.id, "runner");
    expect(sendPush.mock.calls.map((call) => call[1].userId)).toEqual(["user-alice"]);
  });

  it("excludes shared viewers after expiry", async () => {
    await openShared();
    const batch = await edit("Expired itinerary");
    await prepare(batch);
    await env.handle.db.update(summaries).set({ expiresAt: new Date(0) }).where(eq(summaries.id, trip.id));
    await deliverTripNotification(env.handle.db, batch.id, "runner");
    expect(sendPush.mock.calls.map((call) => call[1].userId)).toEqual(["user-alice"]);
  });

  it("does not queue no-op edits or failed edits, and suppresses reverted batches", async () => {
    const noOp = await operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${trip.id}/operations`, {
      token: env.tokens.alice, body: { operations: [{ op: "set_meta", meta: { title: trip.document.title } }] },
    }), params({ id: trip.id }));
    expect(noOp.status).toBe(200);
    expect(await env.handle.db.select().from(batches)).toHaveLength(0);
    const failed = await operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${trip.id}/operations`, {
      token: env.tokens.alice, body: { revision: 99, operations: [{ op: "set_meta", meta: { title: "Stale" } }] },
    }), params({ id: trip.id }));
    expect(failed.status).toBe(409);
    expect(await env.handle.db.select().from(batches)).toHaveLength(0);
    await edit("Temporary title");
    const reverted = await edit(trip.document.title);
    expect(await planTripNotification(env.handle.db, reverted.id, "runner", reverted.dueAt)).toEqual({ status: "done" });
    expect(await env.handle.db.select().from(batches)).toHaveLength(0);
    expect(env.ai.calls.summarizeTripChanges).toHaveLength(0);
  });

  it("invalidates a summary if an edit arrives while the agent runs, and fences duplicate workflows", async () => {
    const batch = await edit("First change");
    const plan = await planTripNotification(env.handle.db, batch.id, "runner", batch.dueAt);
    if (plan.status !== "summarize") throw new Error("Expected summary plan");
    expect(await planTripNotification(env.handle.db, batch.id, "duplicate", batch.dueAt)).toEqual({ status: "done" });
    const next = await edit("Second change");
    expect(await publishTripNotification(env.handle.db, batch.id, "runner", plan.revision, "Stale summary")).toBe(false);
    await prepare(next, "new-runner");
    await deliverTripNotification(env.handle.db, batch.id, "runner");
    expect(sendPush).not.toHaveBeenCalled();
    await deliverTripNotification(env.handle.db, batch.id, "new-runner");
    expect(sendPush).toHaveBeenCalledTimes(1);
  });

  it("retries failed recipients while skipping installations already accepted by APNs", async () => {
    await openShared();
    const batch = await edit("Final itinerary");
    await prepare(batch);
    sendPush.mockImplementation(async (device) => device.token.startsWith("b") ? { status: 503 } : { status: 200 });
    await expect(deliverTripNotification(env.handle.db, batch.id, "runner")).rejects.toThrow("503");
    expect(await env.handle.db.select().from(deliveries)).toHaveLength(1);
    sendPush.mockResolvedValue({ status: 200 });
    await deliverTripNotification(env.handle.db, batch.id, "runner");
    expect(sendPush.mock.calls.filter((call) => call[1].userId === "user-alice")).toHaveLength(1);
    expect(sendPush.mock.calls.filter((call) => call[1].userId === "user-bob")).toHaveLength(2);
  });

  it("fans out across bounded steps and starts a separate batch for edits after publishing", async () => {
    for (let index = 1; index <= 20; index += 1) {
      await devicesRoute.POST(apiRequest("POST", "/api/v1/devices", { token: env.tokens.alice, body: {
        installationId: crypto.randomUUID(), token: index.toString(16).padStart(64, "0"), environment: "sandbox", platform: "ios",
      } }));
    }
    const batch = await edit("Published trip");
    await prepare(batch);
    const next = await edit("Next update");
    expect(next.id).not.toBe(batch.id);
    expect(next.beforeDocument.title).toBe("Published trip");
    expect(await deliverTripNotification(env.handle.db, batch.id, "runner")).toBe(false);
    expect(sendPush).toHaveBeenCalledTimes(20);
    expect(await planTripNotification(env.handle.db, batch.id, "runner")).toEqual({ status: "deliver" });
    expect(await deliverTripNotification(env.handle.db, batch.id, "runner")).toBe(true);
    expect(sendPush).toHaveBeenCalledTimes(21);
    expect(new Set(sendPush.mock.calls.map((call) => call[0].token)).size).toBe(21);
    expect((await env.handle.db.select().from(batches)).map((row) => row.id)).toEqual([next.id]);
  });

  it("recovers interrupted starts and expired leases and restricts cron access", async () => {
    const batch = await edit("Recovered trip", new Date(Date.now() - 1000));
    started.splice(0);
    expect(await resumeTripNotifications(env.handle.db)).toEqual({ restarted: 1 });
    await prepare(batch);
    expect(await resumeTripNotifications(env.handle.db)).toEqual({ restarted: 0 });
    await env.handle.db.update(batches).set({ leaseUntil: new Date(0) }).where(eq(batches.id, batch.id));
    expect(await planTripNotification(env.handle.db, batch.id, "recovery")).toEqual({ status: "deliver" });
    await deliverTripNotification(env.handle.db, batch.id, "recovery");
    expect(sendPush).toHaveBeenCalledTimes(1);
    vi.stubEnv("CRON_SECRET", "secret");
    expect((await cronRoute.GET(apiRequest("GET", "/api/cron/trip-notifications"))).status).toBe(401);
    expect((await cronRoute.GET(apiRequest("GET", "/api/cron/trip-notifications", { token: "secret" }))).status).toBe(200);
  });

  it("removes pending snapshots when a trip or its creator is deleted", async () => {
    await edit("Deleted trip");
    await env.handle.db.delete(users).where(eq(users.id, "user-alice"));
    expect(await env.handle.db.select().from(batches)).toHaveLength(0);
    expect(sendPush).not.toHaveBeenCalled();
  });

  it("fences the outbox and derived summary during concurrent revision saves", async () => {
    const save = (title: string) => tripRoute.PUT(apiRequest("PUT", `/api/v1/trips/${trip.id}`, {
      token: env.tokens.alice, body: { revision: 0, document: { ...trip.document, title } },
    }), params({ id: trip.id }));
    const responses = await Promise.all([save("First contender"), save("Second contender")]);
    expect(responses.map((response) => response.status).sort()).toEqual([200, 409]);
    const winner = (await responses.find((response) => response.status === 200)!.json()).trip;
    const [batch] = await env.handle.db.select().from(batches);
    const [summary] = await env.handle.db.select().from(summaries).where(eq(summaries.id, trip.id));
    expect(batch.afterDocument.title).toBe(winner.document.title);
    expect(batch.beforeDocument.title).toBe(document.title);
    expect(batch.revision).toBe(1);
    expect(summary.title).toBe(winner.document.title);
    expect(await env.handle.db.select().from(batches)).toHaveLength(1);
  });
});
