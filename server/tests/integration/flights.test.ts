import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as devicesRoute from "@/app/api/v1/devices/route";
import * as startTokenRoute from "@/app/api/v1/devices/live-activity/route";
import * as liveActivityRoute from "@/app/api/v1/flights/[flightId]/live-activity/route";
import * as lookupRoute from "@/app/api/v1/flights/lookup/route";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as tripRoute from "@/app/api/v1/trips/[id]/route";
import * as tripFlightsRoute from "@/app/api/v1/trips/[id]/flights/route";
import { flightLiveActivities, flights, flightSubscriptions } from "@/lib/db/schema";
import { MockFlightProvider } from "@/lib/flights/mock";
import { FlightProviderError, setFlightProviderForTests, type FlightProvider, type ProviderFlight } from "@/lib/flights/provider";
import { HOUR, MINUTE } from "@/lib/flights/schedule";
import { refreshTrackedFlight } from "@/lib/services/flights";
import type { TripJson } from "@/lib/services/trips";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));

let env: TestEnv;
const FLIGHT_ID = "CX520-2026-10-12";
const departure = Date.parse("2026-10-12T01:00:00Z");
const landing = Date.parse("2026-10-12T05:30:00Z");
const device = { installationId: "f6daa60d-d123-47a2-8512-596ffb2a9872", token: "a".repeat(64), environment: "sandbox", platform: "ios" };

/** A provider whose answer the test edits between refreshes. */
class ScriptedProvider implements FlightProvider {
  readonly id = "scripted";
  flight: ProviderFlight | null = null;
  failure: Error | null = null;
  calls = 0;
  async lookup() {
    this.calls += 1;
    if (this.failure) throw this.failure;
    return this.flight ? [structuredClone(this.flight)] : [];
  }
}

let provider: ScriptedProvider;

beforeEach(async () => {
  env = await setupTestEnv();
  provider = new ScriptedProvider();
  provider.flight = (await new MockFlightProvider().lookup({ flightNumber: "CX520", date: "2026-10-12" }))[0];
  setFlightProviderForTests(provider);
  sendPush.mockReset().mockResolvedValue({ status: 200 });
  apnsConfigured.mockReset().mockReturnValue(true);
});
afterEach(() => { env.teardown(); vi.restoreAllMocks(); });

const lookup = (body: unknown, token = env.tokens.alice) => lookupRoute.POST(apiRequest("POST", "/api/v1/flights/lookup", { token, body }));

function tripBody(flightNumber = "CX 520") {
  return {
    document: {
      title: "Tokyo", startDate: "2026-10-12", endDate: "2026-10-15", timeZone: "Asia/Tokyo",
      places: [], days: [],
      transports: [{
        id: "out", date: "2026-10-12", label: "HKG → NRT", status: "booked",
        options: [{ id: "cx", label: flightNumber, segments: [{ mode: "flight", fromName: "Hong Kong", toName: "Narita", departure: "2026-10-12T09:00", flight: { flightNumber } }] }],
      }],
    },
  };
}

async function createTrip(token = env.tokens.alice, flightNumber = "CX 520"): Promise<TripJson> {
  const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", { token, body: tripBody(flightNumber) }));
  expect(response.status).toBe(201);
  return (await response.json()).trip;
}

async function subscriptions() {
  return env.handle.db.select().from(flightSubscriptions);
}

async function registerDevice(withStartToken = true) {
  expect((await devicesRoute.POST(apiRequest("POST", "/api/v1/devices", { token: env.tokens.alice, body: device }))).status).toBe(204);
  if (withStartToken) {
    expect((await startTokenRoute.POST(apiRequest("POST", "/api/v1/devices/live-activity", { token: env.tokens.alice, body: { installationId: device.installationId, pushToStartToken: "b".repeat(64) } }))).status).toBe(204);
  }
}

const refresh = (now: number) => refreshTrackedFlight(env.handle.db, FLIGHT_ID, { now: () => now });
const pushesOfType = (type: "alert" | "liveactivity") => sendPush.mock.calls.filter(([, , options]) => (options?.type ?? "alert") === type);

describe("flight lookup", () => {
  it("returns the flight card and stores it", async () => {
    const response = await lookup({ flightNumber: "cx 520", date: "2026-10-12" });
    expect(response.status).toBe(200);
    const { flight } = await response.json();
    expect(flight).toMatchObject({ id: FLIGHT_ID, flightNumber: "CX 520", status: "scheduled", departure: { iata: "HKG", terminal: "1" }, arrival: { iata: "NRT" }, delayMinutes: 0 });
    const [row] = await env.handle.db.select().from(flights);
    expect(row).toMatchObject({ id: FLIGHT_ID, state: "found", trackingState: "idle" });
  });

  it("answers repeated lookups from the database", async () => {
    await lookup({ flightNumber: "CX520", date: "2026-10-12" });
    await lookup({ flightNumber: "CX 520", date: "2026-10-12" });
    expect(provider.calls).toBe(1);
  });

  it("reports an unknown flight as 404 FLIGHT_NOT_FOUND", async () => {
    provider.flight = null;
    const response = await lookup({ flightNumber: "ZZ 9", date: "2026-10-12" });
    expect(response.status).toBe(404);
    expect((await response.json()).error).toMatchObject({ code: "FLIGHT_NOT_FOUND", message: "No flight ZZ 9 was found on 2026-10-12." });
  });

  it("validates the request and requires sign-in", async () => {
    expect((await lookup({ flightNumber: "hello", date: "2026-10-12" })).status).toBe(400);
    expect((await lookup({ flightNumber: "CX520", date: "12/10/2026" })).status).toBe(400);
    expect((await lookupRoute.POST(apiRequest("POST", "/api/v1/flights/lookup", { body: { flightNumber: "CX520", date: "2026-10-12" } }))).status).toBe(401);
  });

  it("is a 502 when the provider fails and nothing is stored", async () => {
    provider.failure = new FlightProviderError("down");
    expect((await lookup({ flightNumber: "CX520", date: "2026-10-12" })).status).toBe(502);
  });
});

describe("trip flight tracking", () => {
  it("subscribes a trip's flights on save, starts one tracker and lists them from the database", async () => {
    const trip = await createTrip();
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(1));
    expect(env.tracker.started).toEqual([FLIGHT_ID]);
    const pending = await (await tripFlightsRoute.GET(apiRequest("GET", `/api/v1/trips/${trip.id}/flights`, { token: env.tokens.alice }), params({ id: trip.id }))).json();
    expect(pending.flights).toEqual([expect.objectContaining({ transportId: "out", optionId: "cx", segmentIndex: 0, flightId: FLIGHT_ID, state: "pending", flight: null })]);
    expect(provider.calls).toBe(0);

    await refresh(departure - 5 * 24 * HOUR);
    const listed = await (await tripFlightsRoute.GET(apiRequest("GET", `/api/v1/trips/${trip.id}/flights`, { token: env.tokens.alice }), params({ id: trip.id }))).json();
    expect(listed.flights[0]).toMatchObject({ state: "found", flight: { flightNumber: "CX 520", departure: { iata: "HKG" } } });

    // A second trip on the same flight shares the tracker.
    await createTrip(env.tokens.bob);
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(2));
    expect(env.tracker.started).toEqual([FLIGHT_ID]);
  });

  it("unsubscribes when the flight is changed or removed", async () => {
    const trip = await createTrip();
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(1));
    const body = tripBody("JL 735");
    expect((await tripRoute.PUT(apiRequest("PUT", `/api/v1/trips/${trip.id}`, { token: env.tokens.alice, body: { ...body, revision: trip.revision } }), params({ id: trip.id }))).status).toBe(200);
    await vi.waitFor(async () => expect((await subscriptions()).map((row) => row.flightId)).toEqual(["JL735-2026-10-12"]));
  });

  it("stops polling a flight nobody follows", async () => {
    const trip = await createTrip();
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(1));
    expect((await tripRoute.DELETE(apiRequest("DELETE", `/api/v1/trips/${trip.id}`, { token: env.tokens.alice }), params({ id: trip.id }))).status).toBe(204);
    expect(await refresh(departure - HOUR)).toMatchObject({ done: true });
    expect(provider.calls).toBe(0);
  });

  it("alerts on a delay, a gate and boarding, then landing, and stops 15 minutes after landing", async () => {
    await registerDevice(false);
    const trip = await createTrip();
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(1));
    await refresh(departure - 2 * 24 * HOUR);
    expect(pushesOfType("alert")).toHaveLength(0);

    provider.flight!.departure.estimated = "2026-10-12T01:45:00.000Z";
    provider.flight!.departure.estimatedLocal = "2026-10-12T09:45";
    const plan = await refresh(departure - 6 * HOUR);
    expect(plan).toMatchObject({ done: false });
    expect(sendPush).toHaveBeenCalledWith(expect.objectContaining({ token: device.token }), expect.objectContaining({
      aps: { alert: { title: "CX 520 delayed", body: "Now departs 09:45 (+45 min) from HKG" }, sound: "default", "thread-id": FLIGHT_ID },
      tripId: trip.id, flightId: FLIGHT_ID,
    }), { collapseId: `${FLIGHT_ID}:time_change` });

    sendPush.mockClear();
    provider.flight!.departure.gate = "B12";
    provider.flight!.status = "boarding";
    await refresh(departure);
    expect(pushesOfType("alert").map(([, payload]) => payload.aps.alert.title)).toEqual(["CX 520 gate update", "CX 520 boarding"]);

    sendPush.mockClear();
    provider.flight!.status = "landed";
    provider.flight!.arrival.actual = new Date(landing).toISOString();
    provider.flight!.arrival.baggageBelt = "7";
    expect(await refresh(landing + 5 * MINUTE)).toEqual({ done: false, nextAt: landing + 10 * MINUTE });
    expect(pushesOfType("alert").map(([, payload]) => payload.aps.alert.body)).toEqual(["Landed in Tokyo · baggage belt 7"]);
    expect(await refresh(landing + 15 * MINUTE)).toMatchObject({ done: true });
    const [row] = await env.handle.db.select().from(flights);
    expect(row).toMatchObject({ trackingState: "finished", landedAt: new Date(landing) });
  });

  it("push-starts the Live Activity 4 hours before departure, updates it and ends it after landing", async () => {
    await registerDevice();
    await createTrip();
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(1));
    await refresh(departure - 5 * HOUR);
    expect(pushesOfType("liveactivity")).toHaveLength(0);

    await refresh(departure - 4 * HOUR);
    const [start] = pushesOfType("liveactivity");
    expect(start[0]).toEqual({ token: "b".repeat(64), environment: "sandbox" });
    expect(start[1].aps).toMatchObject({ event: "start", "attributes-type": "FlightActivityAttributes", attributes: { flightId: FLIGHT_ID, fromIATA: "HKG", toIATA: "NRT" }, "content-state": { status: "scheduled", departureBest: departure / 1000 }, "input-push-token": 1 });
    expect((await subscriptions())[0].liveActivityStartedAt).toEqual(new Date(departure - 4 * HOUR));

    // The device reports the activity's update token; later changes go to it.
    const register = await liveActivityRoute.PUT(apiRequest("PUT", `/api/v1/flights/${FLIGHT_ID}/live-activity`, { token: env.tokens.alice, body: { installationId: device.installationId, token: "c".repeat(64), environment: "sandbox" } }), params({ flightId: FLIGHT_ID }));
    expect(register.status).toBe(204);
    sendPush.mockClear();
    provider.flight!.departure.gate = "B12";
    await refresh(departure - 3 * HOUR);
    const updates = pushesOfType("liveactivity");
    expect(updates).toHaveLength(1);
    expect(updates[0][0]).toMatchObject({ token: "c".repeat(64) });
    expect(updates[0][1].aps).toMatchObject({ event: "update", "content-state": { departureGate: "B12" }, alert: { title: "CX 520 gate update" } });

    // Nothing changed: no update push.
    sendPush.mockClear();
    await refresh(departure - 2 * HOUR);
    expect(pushesOfType("liveactivity")).toHaveLength(0);

    provider.flight!.status = "landed";
    provider.flight!.arrival.actual = new Date(landing).toISOString();
    await refresh(landing + 15 * MINUTE);
    const end = pushesOfType("liveactivity").at(-1)!;
    expect(end[1].aps).toMatchObject({ event: "end", "dismissal-date": (landing + 15 * MINUTE) / 1000 });
    expect(await env.handle.db.select().from(flightLiveActivities)).toEqual([]);
  });

  it("does not push-start when the app already reported a running activity", async () => {
    await registerDevice();
    await createTrip();
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(1));
    await refresh(departure - 5 * HOUR);
    await liveActivityRoute.PUT(apiRequest("PUT", `/api/v1/flights/${FLIGHT_ID}/live-activity`, { token: env.tokens.alice, body: { installationId: device.installationId, token: "c".repeat(64), environment: "sandbox" } }), params({ flightId: FLIGHT_ID }));
    sendPush.mockClear();
    await refresh(departure - 4 * HOUR);
    expect(pushesOfType("liveactivity").filter(([, payload]) => payload.aps.event === "start")).toHaveLength(0);
  });

  it("refuses Live Activity tokens for flights outside the user's trips", async () => {
    await createTrip();
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(1));
    const response = await liveActivityRoute.PUT(apiRequest("PUT", `/api/v1/flights/${FLIGHT_ID}/live-activity`, { token: env.tokens.bob, body: { installationId: device.installationId, token: "c".repeat(64), environment: "sandbox" } }), params({ flightId: FLIGHT_ID }));
    expect(response.status).toBe(404);
  });

  it("keeps the stored flight and retries later when the provider fails", async () => {
    await createTrip();
    await vi.waitFor(async () => expect(await subscriptions()).toHaveLength(1));
    await refresh(departure - 2 * HOUR);
    provider.failure = new FlightProviderError("down", 30 * MINUTE);
    expect(await refresh(departure - HOUR)).toEqual({ done: false, nextAt: departure - 30 * MINUTE });
    const [row] = await env.handle.db.select().from(flights).where(eq(flights.id, FLIGHT_ID));
    expect(row.state).toBe("found");
  });
});
