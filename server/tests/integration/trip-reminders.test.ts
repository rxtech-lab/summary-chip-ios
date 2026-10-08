import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as viewsRoute from "@/app/api/v1/views/route";
import * as devicesRoute from "@/app/api/v1/devices/route";
import { pushDevices, summaries, tripReminderBriefings as briefings, tripReminderDeliveries as deliveries, tripReminderSchedules as schedules, tripWeather, trips, users } from "@/lib/db/schema";
import { refreshTripReminders, resumeTripReminders, syncTripReminders } from "@/lib/services/trip-reminders";
import { replaceTrip, selectPlanOption, type TripJson } from "@/lib/services/trips";
import { setTripReminderSchedulerForTests } from "@/lib/trips/reminders";
import { refreshTripWeather } from "@/lib/services/weather";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));
const itinerary = {
  title: "Kyoto weekend", startDate: "2030-04-01", endDate: "2030-04-01", timeZone: "Asia/Tokyo",
  days: [{ id: "d1", date: "2030-04-01", title: "Arrive" }],
  transports: [{ id: "train", date: "2030-04-01", label: "Airport to Kyoto", options: [{ id: "haruka", label: "Haruka", segments: [
    { mode: "train", fromName: "Airport", toName: "Osaka", departure: "2030-04-01T09:00" },
    { mode: "train", fromName: "Osaka", toName: "Kyoto", departure: "2030-04-01T09:45" },
  ] }] }],
};
const evening = new Date("2030-03-31T11:00:00Z");
const departure = new Date("2030-04-01T00:00:00Z");
let env: TestEnv;
let trip: TripJson;
let started: { tripId: string; runnerId: string }[];

beforeEach(async () => {
  env = await setupTestEnv();
  sendPush.mockReset().mockResolvedValue({ status: 200 });
  apnsConfigured.mockReset().mockReturnValue(true);
  started = [];
  setTripReminderSchedulerForTests({ start: async (tripId, runnerId) => { started.push({ tripId, runnerId }); } });
  for (const [token, char] of [[env.tokens.alice, "a"], [env.tokens.bob, "b"]]) {
    expect((await devicesRoute.POST(apiRequest("POST", "/api/v1/devices", { token, body: {
      installationId: crypto.randomUUID(), token: char.repeat(64), environment: "sandbox", platform: "ios",
    } }))).status).toBe(204);
  }
  const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", { token: env.tokens.alice, body: { document: itinerary, visibility: "public" } }));
  expect(response.status).toBe(201);
  trip = (await response.json()).trip;
  await vi.waitFor(() => expect(started).toHaveLength(1));
});
afterEach(() => env.teardown());
async function run() {
  const [row] = await env.handle.db.select().from(schedules).where(eq(schedules.tripId, trip.id));
  return row;
}
async function openShared() {
  expect((await viewsRoute.POST(apiRequest("POST", "/api/v1/views", { token: env.tokens.bob, body: { slug: trip.slug } }))).status).toBe(200);
}
async function refresh(at: Date) { return refreshTripReminders(env.handle.db, trip.id, (await run()).runnerId, at); }

describe("trip itinerary reminders", () => {
  it("schedules creation, sends a short reminder the previous evening, and skips accepted installations on repeats", async () => {
    await openShared();
    expect(await refresh(new Date(evening.getTime() - 1))).toEqual({ done: false, nextAt: evening.getTime() });
    expect(sendPush).not.toHaveBeenCalled();
    expect(await refresh(evening)).toEqual({ done: false, nextAt: departure.getTime() });
    expect(sendPush.mock.calls.map((call) => call[1].userId).sort()).toEqual(["user-alice", "user-bob"]);
    expect(sendPush.mock.calls[0][1]).toMatchObject({ tripId: trip.id, summaryId: trip.id, aps: { alert: { title: "Tomorrow's trip" } } });
    expect(sendPush.mock.calls[0][1].aps.alert.body).toContain("Arrive");
    expect(env.ai.calls.briefTripDay).toHaveLength(1);
    expect(sendPush.mock.calls[0][2]).toMatchObject({ collapseId: expect.stringMatching(/^[a-f0-9]{64}$/), expiration: Date.parse("2030-03-31T15:00:00Z") / 1000 });
    await refresh(new Date(evening.getTime() + 1000));
    expect(sendPush).toHaveBeenCalledTimes(2);
    expect(env.ai.calls.briefTripDay).toHaveLength(1);
  });

  it("sends at each leg's departure, only to users who follow the trip", async () => {
    await refresh(new Date(departure.getTime() - 1));
    expect(sendPush).not.toHaveBeenCalled();
    expect(await refresh(departure)).toEqual({ done: false, nextAt: Date.parse("2030-04-01T00:45:00Z") });
    expect(sendPush.mock.calls[0][1]).toMatchObject({ userId: "user-alice", aps: { alert: { title: "Your next leg starts now", body: "Kyoto weekend: 09:00 Airport → Osaka" } } });
    expect(sendPush.mock.calls[0][2].expiration).toBe((departure.getTime() + 10 * 60_000) / 1000);
    expect(await refresh(new Date("2030-04-01T00:45:00Z"))).toEqual({ done: true });
    expect(sendPush.mock.calls[1][1].aps.alert.body).toContain("09:45 Osaka → Kyoto");
    expect(sendPush.mock.calls[0][2].collapseId).not.toBe(sendPush.mock.calls[1][2].collapseId);
  });

  it("does not send stale day or leg reminders when a workflow recovers late", async () => {
    await refresh(new Date("2030-03-31T15:00:00Z"));
    await refresh(new Date(departure.getTime() + 10 * 60_000));
    expect(sendPush).not.toHaveBeenCalled();
    expect(await refresh(new Date("2030-04-01T01:00:00Z"))).toEqual({ done: true });
  });

  it.each(["private", "expired"])("excludes shared readers when the trip becomes %s", async (state) => {
    await openShared();
    await env.handle.db.update(summaries).set(state === "private" ? { visibility: "private" } : { expiresAt: new Date(0) }).where(eq(summaries.id, trip.id));
    await refresh(evening);
    expect(sendPush.mock.calls.map((call) => call[1].userId)).toEqual(["user-alice"]);
  });

  it("rechecks plans while sending and follows different reader choices at subsequent departures", async () => {
    await openShared();
    const document = structuredClone(trip.document);
    document.plans = [{ id: "route", title: "Route", scope: "trip", options: [{ id: "a", label: "Train" }, { id: "b", label: "Bus" }] }];
    document.transports[0].planOptionId = "a";
    document.transports.push({ ...document.transports[0], id: "bus", label: "Airport bus", planOptionId: "b", options: [{ id: "bus-option", label: "Airport bus", departure: "2030-04-01T09:15", notes: [], segments: [] }] });
    await replaceTrip(env.handle.db, "user-alice", trip.id, { revision: 0, document });
    await vi.waitFor(() => expect(started).toHaveLength(2));
    // Bob initially follows the default; Alice's push switches Bob to the bus during this fan-out.
    sendPush.mockImplementationOnce(async () => {
      await selectPlanOption(env.handle.db, "user-bob", trip.id, { planId: "route", optionId: "b" });
      return { status: 200 };
    });
    await refresh(departure);
    expect(sendPush.mock.calls.map((call) => call[1].userId)).toEqual(["user-alice"]);
    await refresh(new Date("2030-04-01T00:15:00Z"));
    expect(sendPush.mock.calls[1][1]).toMatchObject({ userId: "user-bob", aps: { alert: { body: "Kyoto weekend: 09:15 Airport bus · Airport bus" } } });
    await refresh(new Date("2030-04-01T00:45:00Z"));
    expect(sendPush.mock.calls.map((call) => call[1].userId)).toEqual(["user-alice", "user-bob", "user-alice"]);
  });

  it("reschedules edited departures, fences the old run, and preserves receipts through later edits", async () => {
    const old = await run();
    const document = structuredClone(trip.document);
    document.transports[0].options[0].segments[0].departure = "2030-04-01T09:20";
    await replaceTrip(env.handle.db, "user-alice", trip.id, { revision: 0, document });
    await vi.waitFor(() => expect(started).toHaveLength(2));
    expect(await refreshTripReminders(env.handle.db, trip.id, old.runnerId, departure)).toEqual({ done: true });
    expect(await refresh(departure)).toEqual({ done: false, nextAt: Date.parse("2030-04-01T00:20:00Z") });
    expect(sendPush).not.toHaveBeenCalled();
    await refresh(new Date("2030-04-01T00:20:00Z"));
    await replaceTrip(env.handle.db, "user-alice", trip.id, { revision: 1, document: { ...document, title: "Updated title" } });
    await vi.waitFor(() => expect(started).toHaveLength(3));
    await refresh(new Date("2030-04-01T00:21:00Z"));
    expect(sendPush).toHaveBeenCalledTimes(1);
  });

  it("retries failed recipients while preserving successful receipts", async () => {
    await openShared();
    sendPush.mockImplementation(async (device) => device.ownerId === "user-bob" ? { status: 503 } : { status: 200 });
    await expect(refresh(evening)).rejects.toThrow("503");
    expect(await env.handle.db.select().from(deliveries)).toHaveLength(1);
    sendPush.mockResolvedValue({ status: 200 });
    await refresh(evening);
    expect(sendPush.mock.calls.filter((call) => call[1].userId === "user-alice")).toHaveLength(1);
    expect(sendPush.mock.calls.filter((call) => call[1].userId === "user-bob")).toHaveLength(2);
    expect(env.ai.calls.briefTripDay).toHaveLength(1);
  });

  it("combines itinerary and weather into one agent-written alert per recipient's selected plan", async () => {
    await openShared();
    const document = structuredClone(trip.document);
    document.places = [
      { id: "kyoto", name: "Kyoto", kind: "city", major: true, coordinate: { lat: 35.0116, lng: 135.7681 }, photos: [], pricing: [] },
      { id: "nara", name: "Nara", kind: "city", major: false, coordinate: { lat: 34.6851, lng: 135.8048 }, photos: [], pricing: [] },
    ];
    document.plans = [{ id: "route", title: "Route", scope: "trip", options: [{ id: "a", label: "Kyoto" }, { id: "b", label: "Nara" }] }];
    document.days[0] = { ...document.days[0], title: "Temple walk", planOptionId: "a", route: { kind: "side", placeIds: ["kyoto"] }, tip: "Pack the rail pass" };
    document.days.push({ ...document.days[0], id: "nara-day", title: "Deer park", planOptionId: "b", route: { kind: "side", placeIds: ["nara"] } });
    document.transports[0].planOptionId = "a";
    document.transports.push({ ...document.transports[0], id: "bus", label: "Bus to Nara", planOptionId: "b", options: [{ id: "bus-option", label: "Bus", departure: "2030-04-01T09:15", notes: [], segments: [] }] });
    await replaceTrip(env.handle.db, "user-alice", trip.id, { revision: 0, document });
    await vi.waitFor(() => expect(started).toHaveLength(2));
    await selectPlanOption(env.handle.db, "user-bob", trip.id, { planId: "route", optionId: "b" });
    await refreshTripWeather(env.handle.db, trip.id, { now: () => evening.getTime(), provider: {
      id: "briefing-weather", forecast: async (points) => points.map(() => ({ timeZone: "Asia/Tokyo", current: null, nowcast: [], daily: [{
        date: "2030-04-01", code: 61, high: 18, low: 9, precipitationChance: 70, precipitation: 5, windMax: 15, gustsMax: 30, uvIndexMax: 4, sunrise: null, sunset: null,
      }] })),
    } });
    expect(sendPush).not.toHaveBeenCalled();
    await refresh(evening);
    expect(sendPush).toHaveBeenCalledTimes(2);
    expect(env.ai.calls.briefTripDay).toHaveLength(2);
    const [alice, bob] = env.ai.calls.briefTripDay;
    expect(alice).toMatchObject({ days: [{ title: "Temple walk", tip: "Pack the rail pass" }], weather: [{ place: "Kyoto", condition: "rain", precipitationChance: 70 }] });
    expect(bob).toMatchObject({ days: [{ title: "Deer park" }], transports: [{ departure: "2030-04-01T09:15" }], weather: [{ place: "Nara", condition: "rain" }] });
    expect(JSON.stringify(bob)).not.toContain("Temple walk");
    expect(sendPush.mock.calls[0][1].aps.alert.body).toContain("Kyoto: rain");
    expect(sendPush.mock.calls[1][1].aps.alert.body).toContain("Nara: rain");
    await refresh(evening);
    expect(sendPush).toHaveBeenCalledTimes(2);
  });

  it.each(["fails", "returns empty text", "returns oversized text"])("falls back to the saved itinerary when the agent %s", async (failure) => {
    const agent = vi.spyOn(env.ai, "briefTripDay");
    if (failure === "fails") agent.mockRejectedValue(new Error("Agent unavailable"));
    else agent.mockResolvedValue(failure === "returns empty text" ? " " : "x".repeat(141));
    await refresh(evening);
    expect(sendPush.mock.calls[0][1].aps.alert.body).toContain("2030-04-01 · Arrive");
    expect(await env.handle.db.select().from(briefings)).toHaveLength(1);
    await refresh(evening);
    expect(agent).toHaveBeenCalledTimes(1);
    expect(sendPush).toHaveBeenCalledTimes(1);
  });

  it("sends coinciding departure alerts before generating the evening briefing", async () => {
    await openShared();
    const document = structuredClone(trip.document);
    document.startDate = document.transports[0].date = "2030-03-31";
    document.transports[0].options[0].segments[0].departure = "2030-03-31T20:00";
    await replaceTrip(env.handle.db, "user-alice", trip.id, { revision: 0, document });
    await vi.waitFor(() => expect(started).toHaveLength(2));
    vi.spyOn(env.ai, "briefTripDay").mockImplementation(async () => {
      expect(sendPush.mock.calls.filter((call) => call[1].aps.alert.title === "Your next leg starts now").map((call) => call[1].userId)).toEqual(["user-alice", "user-bob"]);
      return "Tomorrow: Arrive in Kyoto.";
    });
    await refresh(evening);
    expect(sendPush).toHaveBeenCalledTimes(4);
    expect(sendPush.mock.calls.map((call) => call[1].aps.alert.title)).toEqual(["Your next leg starts now", "Your next leg starts now", "Tomorrow's trip", "Tomorrow's trip"]);
  });

  it("regenerates the briefing if the forecast changes while the agent runs", async () => {
    const document = structuredClone(trip.document);
    document.places = [{ id: "kyoto", name: "Kyoto", kind: "city", major: true, coordinate: { lat: 35.0116, lng: 135.7681 }, photos: [], pricing: [] }];
    document.days[0].route = { kind: "side", placeIds: ["kyoto"] };
    await replaceTrip(env.handle.db, "user-alice", trip.id, { revision: 0, document });
    await vi.waitFor(() => expect(started).toHaveLength(2));
    await refreshTripWeather(env.handle.db, trip.id, { now: () => evening.getTime(), provider: {
      id: "briefing-weather", forecast: async (points) => points.map(() => ({ timeZone: "Asia/Tokyo", current: null, nowcast: [], daily: [{
        date: "2030-04-01", code: 61, high: 18, low: 9, precipitationChance: 70, precipitation: 5, windMax: 15, gustsMax: 30, uvIndexMax: 4, sunrise: null, sunset: null,
      }] })),
    } });
    const agent = vi.spyOn(env.ai, "briefTripDay").mockImplementationOnce(async () => {
      const [stored] = await env.handle.db.select().from(tripWeather).where(eq(tripWeather.tripId, trip.id));
      const data = structuredClone(stored.data!);
      Object.values(data.locations).forEach((location) => { location.daily[0].code = 95; });
      await env.handle.db.update(tripWeather).set({ data }).where(eq(tripWeather.tripId, trip.id));
      return "STALE rain briefing";
    }).mockResolvedValue("09:00 train to Kyoto. Thunderstorms forecast; plan for shelter.");
    expect(await refresh(evening)).toEqual({ done: false, nextAt: evening.getTime() + 1000 });
    expect(sendPush).not.toHaveBeenCalled();
    await refresh(new Date(evening.getTime() + 1000));
    expect(agent.mock.calls[1][0].weather).toMatchObject([{ place: "Kyoto", condition: "thunderstorm" }]);
    expect(sendPush).toHaveBeenCalledTimes(1);
    expect(sendPush.mock.calls[0][1].aps.alert.body).toContain("Thunderstorms forecast");
  });

  it("does not send a stale briefing if the selected plan changes while the agent runs", async () => {
    const document = structuredClone(trip.document);
    document.plans = [{ id: "route", title: "Route", scope: "trip", options: [{ id: "a", label: "Train" }, { id: "b", label: "Bus" }] }];
    document.transports[0].planOptionId = "a";
    document.transports.push({ ...document.transports[0], id: "bus", label: "Airport bus", planOptionId: "b", options: [{ id: "bus-option", label: "Bus", departure: "2030-04-01T09:15", notes: [], segments: [] }] });
    await replaceTrip(env.handle.db, "user-alice", trip.id, { revision: 0, document });
    await vi.waitFor(() => expect(started).toHaveLength(2));
    const agent = vi.spyOn(env.ai, "briefTripDay").mockImplementationOnce(async () => {
      await selectPlanOption(env.handle.db, "user-alice", trip.id, { planId: "route", optionId: "b" });
      return "STALE train briefing";
    }).mockResolvedValue("09:15 Airport bus tomorrow.");
    expect(await refresh(evening)).toEqual({ done: false, nextAt: evening.getTime() + 1000 });
    expect(sendPush).not.toHaveBeenCalled();
    await refresh(new Date(evening.getTime() + 1000));
    expect(agent).toHaveBeenCalledTimes(2);
    expect(sendPush.mock.calls[0][1].aps.alert.body).toBe("Kyoto weekend: 09:15 Airport bus tomorrow.");
  });

  it("rechecks sharing after generation and expires cached briefings", async () => {
    await openShared();
    vi.spyOn(env.ai, "briefTripDay").mockImplementationOnce(async () => {
      await env.handle.db.update(summaries).set({ visibility: "private" }).where(eq(summaries.id, trip.id));
      return "09:00 train to Kyoto tomorrow.";
    });
    await refresh(evening);
    expect(sendPush.mock.calls.map((call) => call[1].userId)).toEqual(["user-alice"]);
    expect(await env.handle.db.select().from(briefings)).toHaveLength(1);
    await resumeTripReminders(env.handle.db, new Date("2030-03-31T15:00:00Z"));
    expect(await env.handle.db.select().from(briefings)).toEqual([]);
  });

  it("deletes generated briefings with the trip", async () => {
    await refresh(evening);
    expect(await env.handle.db.select().from(briefings)).toHaveLength(1);
    await env.handle.db.delete(trips).where(eq(trips.summaryId, trip.id));
    expect(await env.handle.db.select().from(briefings)).toEqual([]);
    expect(await env.handle.db.select().from(deliveries)).toEqual([]);
    expect(await env.handle.db.select().from(schedules)).toEqual([]);
  });

  it("recovers a missed departure wake-up before the leg reminder expires", async () => {
    await refresh(evening);
    const old = await run();
    const recovery = new Date(departure.getTime() + 5 * 60_000);
    expect(await resumeTripReminders(env.handle.db, recovery)).toEqual({ remindersRestarted: 1 });
    expect((await run()).runnerId).not.toBe(old.runnerId);
    await refresh(recovery);
    expect(sendPush.mock.calls.filter((call) => call[1].aps.alert.title === "Your next leg starts now")).toHaveLength(1);
    expect(await refreshTripReminders(env.handle.db, trip.id, old.runnerId, recovery)).toEqual({ done: true });
  });

  it("recovers a failed leg delivery within its remaining delivery window", async () => {
    await refresh(evening);
    sendPush.mockRejectedValueOnce(new Error("APNs connection failed"));
    await expect(refresh(departure)).rejects.toThrow("APNs connection failed");
    expect((await run()).leaseUntil?.getTime()).toBe(departure.getTime() + 60_000);
    const recovery = new Date(departure.getTime() + 5 * 60_000);
    expect(await resumeTripReminders(env.handle.db, recovery)).toEqual({ remindersRestarted: 1 });
    sendPush.mockResolvedValue({ status: 200 });
    await refresh(recovery);
    expect(sendPush.mock.calls.at(-1)?.[1].aps.alert.body).toContain("09:00 Airport → Osaka");
    expect(await env.handle.db.select().from(deliveries)).toHaveLength(2);
  });

  it("stops sending when a device signs out during fan-out and removes dead tokens", async () => {
    await openShared();
    sendPush.mockImplementationOnce(async () => {
      await env.handle.db.delete(pushDevices).where(eq(pushDevices.ownerId, "user-bob"));
      return { status: 410, reason: "Unregistered" };
    });
    await refresh(evening);
    expect(sendPush).toHaveBeenCalledTimes(1);
    expect(await env.handle.db.select().from(pushDevices)).toEqual([]);
  });

  it("bounds fan-out and delivers remaining installations without repeating accepted ones", async () => {
    for (let index = 1; index <= 20; index += 1) {
      await env.handle.db.insert(pushDevices).values({ installationId: crypto.randomUUID(), ownerId: "user-alice", token: index.toString(16).padStart(64, "0"), platform: "ios", environment: "sandbox" });
    }
    expect(await refresh(evening)).toEqual({ done: false, nextAt: evening.getTime() + 1000 });
    expect(sendPush).toHaveBeenCalledTimes(20);
    await refresh(new Date(evening.getTime() + 1000));
    expect(sendPush).toHaveBeenCalledTimes(21);
    expect(new Set(sendPush.mock.calls.map((call) => call[0].installationId)).size).toBe(21);
    expect(env.ai.calls.briefTripDay).toHaveLength(1);
  });

  it("backfills old trips and recovers failed starts and expired leases", async () => {
    await env.handle.db.delete(schedules).where(eq(schedules.tripId, trip.id));
    setTripReminderSchedulerForTests({ start: async () => { throw new Error("Unavailable"); } });
    expect(await resumeTripReminders(env.handle.db, evening)).toEqual({ remindersRestarted: 0 });
    expect((await run()).leaseUntil).toBeNull();
    setTripReminderSchedulerForTests({ start: async (tripId, runnerId) => { started.push({ tripId, runnerId }); } });
    expect(await resumeTripReminders(env.handle.db, evening)).toEqual({ remindersRestarted: 1 });
    const old = await run();
    expect(await resumeTripReminders(env.handle.db, evening)).toEqual({ remindersRestarted: 0 });
    await env.handle.db.update(schedules).set({ leaseUntil: new Date(0) }).where(eq(schedules.tripId, trip.id));
    expect(await resumeTripReminders(env.handle.db, evening)).toEqual({ remindersRestarted: 1 });
    expect((await run()).runnerId).not.toBe(old.runnerId);
    await refresh(evening);
    expect(sendPush).toHaveBeenCalledTimes(1);
    expect(await refreshTripReminders(env.handle.db, trip.id, old.runnerId, evening)).toEqual({ done: true });
  });

  it("skips delivery without APNs and cascades schedules and receipts on deletion", async () => {
    apnsConfigured.mockReturnValue(false);
    await refresh(evening);
    expect(sendPush).not.toHaveBeenCalled();
    expect(await env.handle.db.select().from(deliveries)).toEqual([]);
    expect(await env.handle.db.select().from(briefings)).toEqual([]);
    apnsConfigured.mockReturnValue(true);
    await refresh(departure);
    expect(await env.handle.db.select().from(deliveries)).toHaveLength(1);
    await env.handle.db.delete(users).where(eq(users.id, "user-alice"));
    expect(await env.handle.db.select().from(schedules)).toEqual([]);
    expect(await env.handle.db.select().from(deliveries)).toEqual([]);
    expect(await env.handle.db.select().from(trips)).toEqual([]);
    await syncTripReminders(env.handle.db, trip.id);
    expect(await env.handle.db.select().from(schedules)).toEqual([]);
  });
});
