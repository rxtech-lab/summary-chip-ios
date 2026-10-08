import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as devicesRoute from "@/app/api/v1/devices/route";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as tripRoute from "@/app/api/v1/trips/[id]/route";
import * as tripWeatherRoute from "@/app/api/v1/trips/[id]/weather/route";
import { tripDocumentSchema } from "@/lib/contracts/trip";
import { tripWeather } from "@/lib/db/schema";
import { refreshTripWeather, resumeWeatherTracking, syncTripWeather, tripWeatherForViewer } from "@/lib/services/weather";
import type { TripJson } from "@/lib/services/trips";
import { setWeatherProviderForTests, WeatherProviderError, type LocationForecast, type WeatherPoint, type WeatherProvider } from "@/lib/weather/provider";
import { HOUR, MINUTE } from "@/lib/weather/schedule";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));

let env: TestEnv;
const device = { installationId: "f6daa60d-d123-47a2-8512-596ffb2a9872", token: "a".repeat(64), environment: "sandbox", platform: "ios" };

/** Trip time is Tokyo (UTC+9). */
const tokyo = (local: string) => Date.parse(`${local}:00+09:00`);

/** Forecasts the test edits: the same everywhere, with a nowcast code per 15-minute slot from `nowcastFrom`. */
class ScriptedProvider implements WeatherProvider {
  readonly id = "scripted";
  calls: WeatherPoint[][] = [];
  failure: Error | null = null;
  dailyCode = 61;
  nowcastFrom = 0;
  nowcastCodes: number[] = [1, 1, 1, 1];
  async forecast(points: WeatherPoint[]): Promise<LocationForecast[]> {
    this.calls.push(points);
    if (this.failure) throw this.failure;
    return points.map(() => ({
      timeZone: "Asia/Tokyo",
      current: null,
      daily: ["2030-04-01", "2030-04-02", "2030-04-03"].map((date) => ({
        date, code: this.dailyCode, high: 18, low: 9, precipitationChance: 70, precipitation: 5, windMax: 15, gustsMax: 30, uvIndexMax: 4, sunrise: null, sunset: null,
      })),
      nowcast: this.nowcastCodes.map((code, index) => {
        const at = this.nowcastFrom + index * 15 * MINUTE;
        return { at, local: new Date(at + 9 * HOUR).toISOString().slice(0, 16), code, temperature: 15, precipitation: code >= 61 ? 1 : 0, gusts: 10 };
      }),
    }));
  }
}

let provider: ScriptedProvider;

beforeEach(async () => {
  env = await setupTestEnv();
  provider = new ScriptedProvider();
  setWeatherProviderForTests(provider);
  sendPush.mockReset().mockResolvedValue({ status: 200 });
  apnsConfigured.mockReset().mockReturnValue(true);
});
afterEach(() => { env.teardown(); vi.restoreAllMocks(); });

const tripDocument = {
  title: "Kansai", startDate: "2030-04-01", endDate: "2030-04-03", timeZone: "Asia/Tokyo",
  places: [
    { id: "kyoto", name: "Kyoto", kind: "city", major: true, coordinate: { lat: 35.0116, lng: 135.7681 } },
    { id: "nara", name: "Nara", kind: "city", coordinate: { lat: 34.6851, lng: 135.8048 } },
  ],
  days: [
    { id: "d1", date: "2030-04-01", title: "Kyoto", route: { kind: "side", placeIds: ["kyoto"] } },
    { id: "d2", date: "2030-04-02", title: "Nara", moments: [{ slot: "morning", time: "10:00", text: "Deer", placeId: "nara" }] },
    { id: "d3", date: "2030-04-03", title: "Home" },
  ],
};

async function createTrip(): Promise<TripJson> {
  const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", { token: env.tokens.alice, body: { document: tripDocument } }));
  expect(response.status).toBe(201);
  return (await response.json()).trip;
}

async function registerDevice(timeZone?: string) {
  expect((await devicesRoute.POST(apiRequest("POST", "/api/v1/devices", { token: env.tokens.alice, body: { ...device, timeZone } }))).status).toBe(204);
}

const refresh = (tripId: string, now: number) => refreshTripWeather(env.handle.db, tripId, { now: () => now });
const alerts = () => sendPush.mock.calls.map(([, payload, options]) => ({ ...payload.aps.alert, kind: payload.kind, tripId: payload.tripId, collapseId: options?.collapseId }));
const getWeather = (tripId: string, token = env.tokens.alice) => tripWeatherRoute.GET(apiRequest("GET", `/api/v1/trips/${tripId}/weather`, { token }), params({ id: tripId }));

async function waitForTracking(tripId: string) {
  await vi.waitFor(async () => {
    const [row] = await env.handle.db.select().from(tripWeather).where(eq(tripWeather.tripId, tripId));
    expect(row?.trackingRunId).toBeTruthy();
  });
}

describe("trip weather", () => {
  it("starts one tracker when a trip is saved and serves stored forecasts per day", async () => {
    const trip = await createTrip();
    await waitForTracking(trip.id);
    const before = await (await getWeather(trip.id)).json();
    expect(before).toMatchObject({ updatedAt: null, now: null });
    expect(before.days.map((day: { dayId: string; locations: { name: string; forecast: unknown }[] }) => [day.dayId, day.locations.map((l) => [l.name, l.forecast])]))
      .toEqual([["d1", [["Kyoto", null]]], ["d2", [["Nara", null]]], ["d3", [["Nara", null]]]]);

    const plan = await refresh(trip.id, tokyo("2030-03-30T12:00"));
    expect(plan).toEqual({ done: false, nextAt: tokyo("2030-03-30T15:00") });
    expect(provider.calls).toHaveLength(1);
    expect(provider.calls[0]).toHaveLength(2);
    const after = await (await getWeather(trip.id)).json();
    expect(after.updatedAt).toBe(new Date(tokyo("2030-03-30T12:00")).toISOString());
    expect(after.days[0].locations[0].forecast).toMatchObject({ date: "2030-04-01", condition: "rain", weatherCode: 61, high: 18, low: 9, precipitationChance: 70 });
    expect(sendPush).not.toHaveBeenCalled();
  });

  it("starts tracking a trip saved before weather existed when it is first read", async () => {
    const trip = await createTrip();
    await waitForTracking(trip.id);
    // As if the trip predates the feature: no weather row, no run.
    await env.handle.db.delete(tripWeather).where(eq(tripWeather.tripId, trip.id));
    env.weatherTracker.started.length = 0;
    expect((await getWeather(trip.id)).status).toBe(200);
    await waitForTracking(trip.id);
    expect(env.weatherTracker.started).toEqual([trip.id]);
    // Reading again doesn't start a second run.
    await getWeather(trip.id);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(env.weatherTracker.started).toEqual([trip.id]);
  });

  it("only lets readers of the trip see its weather", async () => {
    const trip = await createTrip();
    expect((await getWeather(trip.id, env.tokens.bob)).status).toBe(404);
    expect((await tripWeatherRoute.GET(apiRequest("GET", `/api/v1/trips/${trip.id}/weather`), params({ id: trip.id }))).status).toBe(401);
  });

  it("sends tomorrow's weather at 20:00 the evening before, once", async () => {
    await registerDevice();
    const trip = await createTrip();
    await waitForTracking(trip.id);
    expect(await refresh(trip.id, tokyo("2030-03-31T18:00"))).toMatchObject({ nextAt: tokyo("2030-03-31T20:00") });
    expect(sendPush).not.toHaveBeenCalled();
    await refresh(trip.id, tokyo("2030-03-31T20:00"));
    expect(alerts()).toEqual([{
      title: "Tomorrow in Kyoto: Rain",
      body: "Kyoto: Rain, 9–18°C, 70% chance of rain. Bring an umbrella.",
      kind: "weather", tripId: trip.id, collapseId: `weather:${trip.id}:2030-04-01`,
    }]);
    await refresh(trip.id, tokyo("2030-03-31T23:00"));
    expect(sendPush).toHaveBeenCalledTimes(1);
    // Too late for the 2nd's alert on the morning of the 2nd.
    await refresh(trip.id, tokyo("2030-04-02T07:00"));
    expect(alerts().map((alert) => alert.collapseId)).toEqual([`weather:${trip.id}:2030-04-01`]);
  });

  it("sends the first day's forecast at 20:00 where the owner's device is, later ones where they are", async () => {
    // At home in Los Angeles before a trip whose places are in Tokyo.
    await registerDevice("America/Los_Angeles");
    const trip = await createTrip();
    await waitForTracking(trip.id);
    // 20:00 in Tokyo is 04:00 in Los Angeles: too early.
    await refresh(trip.id, tokyo("2030-03-31T20:00"));
    expect(sendPush).not.toHaveBeenCalled();
    await refresh(trip.id, Date.parse("2030-03-31T20:00:00-07:00"));
    expect(alerts().map((alert) => alert.collapseId)).toEqual([`weather:${trip.id}:2030-04-01`]);
    // From then on, 20:00 in Tokyo, where the evenings are spent.
    await refresh(trip.id, tokyo("2030-04-01T19:45"));
    expect(sendPush).toHaveBeenCalledTimes(1);
    await refresh(trip.id, tokyo("2030-04-01T20:00"));
    expect(alerts().map((alert) => alert.collapseId)).toEqual([`weather:${trip.id}:2030-04-01`, `weather:${trip.id}:2030-04-02`]);
  });

  it("rejects a device time zone it doesn't know", async () => {
    const response = await devicesRoute.POST(apiRequest("POST", "/api/v1/devices", { token: env.tokens.alice, body: { ...device, timeZone: "Mars/Olympus" } }));
    expect(response.status).toBe(400);
  });

  it("alerts when the next 30 minutes turn bad, and when it clears up", async () => {
    await registerDevice();
    const trip = await createTrip();
    await waitForTracking(trip.id);
    let now = tokyo("2030-04-02T11:00");
    provider.nowcastFrom = now;
    await refresh(trip.id, now);
    expect(sendPush).not.toHaveBeenCalled();

    now += 15 * MINUTE;
    provider.nowcastFrom = now;
    provider.nowcastCodes = [3, 3, 63, 63];
    const plan = await refresh(trip.id, now);
    expect(plan.nextAt).toBe(now + 15 * MINUTE);
    // Only the place the traveller is at was fetched (the full refresh was 15 minutes ago).
    expect(provider.calls.at(-1)).toEqual([{ lat: 34.6851, lng: 135.8048 }]);
    expect(alerts()).toEqual([{ title: "Rain soon in Nara", body: "Rain expected from 11:45. Plan for shelter or cover.", kind: "weather", tripId: trip.id, collapseId: `weather-now:${trip.id}` }]);

    now += 15 * MINUTE;
    provider.nowcastFrom = now;
    await refresh(trip.id, now);
    expect(sendPush).toHaveBeenCalledTimes(1);

    now += 30 * MINUTE;
    provider.nowcastFrom = now;
    provider.nowcastCodes = [2, 2, 1, 1];
    await refresh(trip.id, now);
    expect(alerts().at(-1)).toMatchObject({ title: "Rain easing in Nara" });

    // What the apps read about where the traveller is now.
    const weather = await tripWeatherForViewer(env.handle.db, trip.id, "user-alice", now);
    expect(weather.now).toMatchObject({ dayId: "d2", placeId: "nara", name: "Nara", condition: "partly_cloudy", next30Minutes: { condition: "partly_cloudy" } });
  });

  it("keeps the stored forecast when the provider fails and retries later", async () => {
    const trip = await createTrip();
    await waitForTracking(trip.id);
    await refresh(trip.id, tokyo("2030-03-30T12:00"));
    provider.failure = new WeatherProviderError("down");
    const plan = await refresh(trip.id, tokyo("2030-03-30T15:00"));
    expect(plan.nextAt).toBe(tokyo("2030-03-30T18:00"));
    const [row] = await env.handle.db.select().from(tripWeather).where(eq(tripWeather.tripId, trip.id));
    expect(Object.keys(row.data!.locations)).toHaveLength(2);
  });

  it("finishes after the trip, and starts again when the trip moves to later dates", async () => {
    const trip = await createTrip();
    await waitForTracking(trip.id);
    expect(await refresh(trip.id, tokyo("2030-04-04T00:00"))).toMatchObject({ done: true });
    const [finished] = await env.handle.db.select().from(tripWeather).where(eq(tripWeather.tripId, trip.id));
    expect(finished.trackingState).toBe("finished");
    expect(await resumeWeatherTracking(env.handle.db)).toEqual({ restarted: 0 });

    const moved = { ...tripDocument, startDate: "2030-05-01", endDate: "2030-05-03", days: tripDocument.days.map((day, index) => ({ ...day, date: `2030-05-0${index + 1}` })) };
    await syncTripWeather(env.handle.db, trip.id, tripDocumentSchema.parse(moved), { now: () => tokyo("2030-04-04T00:00") });
    const [restarted] = await env.handle.db.select().from(tripWeather).where(eq(tripWeather.tripId, trip.id));
    expect(restarted.trackingState).toBe("tracking");
    expect(env.weatherTracker.started.filter((id) => id === trip.id)).toHaveLength(2);
  });

  it("stops for a deleted trip", async () => {
    const trip = await createTrip();
    await waitForTracking(trip.id);
    expect((await tripRoute.DELETE(apiRequest("DELETE", `/api/v1/trips/${trip.id}`, { token: env.tokens.alice }), params({ id: trip.id }))).status).toBeLessThan(300);
    expect(await refresh(trip.id, tokyo("2030-03-30T12:00"))).toMatchObject({ done: true });
  });
});
