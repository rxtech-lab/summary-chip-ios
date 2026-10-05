import { readFileSync } from "node:fs";
import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as devicesRoute from "@/app/api/v1/devices/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as tripRoute from "@/app/api/v1/trips/[id]/route";
import * as operationsRoute from "@/app/api/v1/trips/[id]/operations/route";
import * as ingestRoute from "@/app/api/v1/trips/[id]/ingest/route";
import * as chatRoute from "@/app/api/v1/chat/route";
import { tripChatTools } from "@/lib/ai/chat";
import type { TripDocument } from "@/lib/contracts/trip";
import { summaries, trips } from "@/lib/db/schema";
import type { TripJson } from "@/lib/services/trips";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));

const northbound = JSON.parse(readFileSync(new URL("../fixtures/northbound-trip.json", import.meta.url), "utf8")) as TripDocument;

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
  vi.stubEnv("SUMMARY_OG_REMOTE_ASSETS", "false");
  sendPush.mockReset().mockResolvedValue({ status: 200 });
  apnsConfigured.mockReset().mockReturnValue(true);
});

afterEach(() => {
  env.teardown();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

function doc(overrides: Partial<TripDocument> = {}): Partial<TripDocument> {
  return {
    title: "Lisbon long weekend",
    startDate: "2026-11-06",
    endDate: "2026-11-09",
    timeZone: "Europe/Lisbon",
    currency: "EUR",
    places: [{ id: "lisbon", name: "Lisbon", kind: "city", coordinate: { lat: 38.7223, lng: -9.1393 }, major: true, address: null, note: null }],
    days: [{ id: "day-1", date: "2026-11-06", title: "Alfama at dusk", highlight: false, moments: [], transportIds: [], route: null, stayId: null }],
    ...overrides,
  };
}

async function create(body: unknown = { document: doc() }, token = env.tokens.alice): Promise<TripJson> {
  const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", { token, body }));
  expect(response.status).toBe(201);
  return (await response.json()).trip;
}

function get(id: string, token = env.tokens.alice) {
  return tripRoute.GET(apiRequest("GET", `/api/v1/trips/${id}`, { token }), params({ id }));
}

function put(id: string, body: unknown, token = env.tokens.alice) {
  return tripRoute.PUT(apiRequest("PUT", `/api/v1/trips/${id}`, { token, body }), params({ id }));
}

function operations(id: string, body: unknown, token = env.tokens.alice) {
  return operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${id}/operations`, { token, body }), params({ id }));
}

function ingest(id: string, body: unknown, token = env.tokens.alice) {
  return ingestRoute.POST(apiRequest("POST", `/api/v1/trips/${id}/ingest`, { token, body }), params({ id }));
}

async function storedTrip(id: string) {
  return (await env.handle.db.select().from(trips).where(eq(trips.summaryId, id)))[0];
}

describe("/api/v1/trips", () => {
  it("creates a trip as a library item without using the summary allowance", async () => {
    const trip = await create({ document: northbound });
    expect(trip).toMatchObject({ revision: 0, visibility: "private", isOwner: true, document: { title: northbound.title, currency: "JPY" } });
    expect(trip.shareUrl).toMatch(/\/s\/[\w-]+$/);
    expect(trip.document.days).toHaveLength(11);

    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, trip.id));
    expect(row).toMatchObject({ kind: "trip", category: "Travel", tags: ["trip"], title: northbound.title, ttlDays: null, contentMarkdown: null });
    expect(row.highlights[0]).toBe(northbound.days[0].title);
    expect(row.contentText).toContain("Day 3 · 2026-10-12");
    expect(env.ai.calls.summarize).toHaveLength(0);

    // The library lists it with its kind and can filter by kind.
    const library = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?kind=trip", { token: env.tokens.alice }))).json();
    expect(library.items).toEqual([expect.objectContaining({ id: trip.id, kind: "trip" })]);
    const cards = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?kind=summary", { token: env.tokens.alice }))).json();
    expect(cards.items).toEqual([]);
  });

  it("validates the document's integrity", async () => {
    const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", {
      token: env.tokens.alice,
      body: { document: doc({ days: [{ id: "day-1", date: "2026-11-06", title: "x", stayId: "ghost", moments: [], transportIds: [], highlight: false }] }) },
    }));
    expect(response.status).toBe(400);
    expect((await response.json()).error.message).toContain("document.days.0.stayId: unknown id \"ghost\"");
  });

  it("lists ongoing and upcoming trips first, then past ones", async () => {
    const day = (offset: number) => new Date(Date.now() + offset * 86_400_000).toISOString().slice(0, 10);
    await create({ document: doc({ title: "Past", startDate: day(-200), endDate: day(-196), days: [] }) });
    await create({ document: doc({ title: "Later", startDate: day(70), endDate: day(78), days: [] }) });
    await create({ document: doc({ title: "Now", startDate: day(-3), endDate: day(3), days: [] }) });
    await create({ document: doc({ title: "Older", startDate: day(-400), endDate: day(-396), days: [] }) });
    await create({ document: doc({ title: "Bob's" }) }, env.tokens.bob);
    const body = await (await tripsRoute.GET(apiRequest("GET", "/api/v1/trips", { token: env.tokens.alice }))).json();
    expect(body.trips.map((trip: { title: string }) => trip.title)).toEqual(["Now", "Later", "Past", "Older"]);
    expect(body.trips[0]).toMatchObject({ startDate: day(-3), endDate: day(3), revision: 0, dayCount: 7, placeCount: 1, subtitle: null });
  });

  it("shows a trip to its owner, and to others only while public", async () => {
    const trip = await create();
    expect((await get(trip.id)).status).toBe(200);
    expect((await get(trip.id, env.tokens.bob)).status).toBe(404);

    const shared = await create({ document: doc(), visibility: "public" });
    const response = await get(shared.id, env.tokens.bob);
    expect(response.status).toBe(200);
    expect((await response.json()).trip).toMatchObject({ id: shared.id, isOwner: false });
    // …but only the owner edits it.
    expect((await put(shared.id, { document: doc(), revision: 0 }, env.tokens.bob)).status).toBe(403);

    // A summary is not a trip.
    const summary = await (await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token: env.tokens.alice, body: { source: { type: "text", text: "Octopuses have three hearts and blue blood, which helps them in cold water." } } }))).json();
    expect(summary.kind).toBe("summary");
    expect((await get(summary.id)).status).toBe(404);
  });

  it("saves whole documents with optimistic concurrency", async () => {
    const trip = await create();
    const edited = { ...trip.document, title: "Lisbon & Sintra", subtitle: "Four slow days" };
    const saved = await put(trip.id, { document: edited, revision: 0 });
    expect(saved.status).toBe(200);
    expect((await saved.json()).trip).toMatchObject({ revision: 1, document: { title: "Lisbon & Sintra" } });

    const stale = await put(trip.id, { document: { ...trip.document, title: "Stale" }, revision: 0 });
    expect(stale.status).toBe(409);
    expect((await stale.json()).error).toMatchObject({ code: "TRIP_REVISION_CONFLICT", details: { revision: 1 } });

    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, trip.id));
    expect(row.title).toBe("Lisbon & Sintra");
    expect(await storedTrip(trip.id)).toMatchObject({ revision: 1, startDate: "2026-11-06", endDate: "2026-11-09" });
  });

  it("keeps saved views when an older app saves a document without them", async () => {
    const view = { id: "budget", title: "Budget", dayId: null, spec: { root: "t", elements: { t: { type: "Text", props: { text: "€300 total" } } } } };
    const trip = await create({ document: doc({ views: [view] as TripDocument["views"] }) });
    expect(trip.document.views).toHaveLength(1);

    const legacy: Partial<TripDocument> = { ...trip.document };
    delete legacy.views;
    const saved = await put(trip.id, { document: { ...legacy, title: "Lisbon again" }, revision: 0 });
    expect(saved.status).toBe(200);
    expect((await saved.json()).trip.document).toMatchObject({ title: "Lisbon again", views: [{ id: "budget" }] });

    const cleared = await put(trip.id, { document: { ...trip.document, views: [] }, revision: 1 });
    expect((await cleared.json()).trip.document.views).toEqual([]);
  });

  it("applies operations atomically", async () => {
    const trip = await create();
    const response = await operations(trip.id, {
      revision: 0,
      operations: [
        { op: "upsert_place", place: { id: "sintra", name: "Sintra", kind: "city", coordinate: { lat: 38.8029, lng: -9.3817 } } },
        { op: "upsert_hotel", hotel: { id: "hotel-alfama", name: "Memmo Alfama", placeId: "lisbon", checkIn: "2026-11-06", checkOut: "2026-11-09", status: "booked" } },
        { op: "upsert_day", day: { id: "day-2", date: "2026-11-07", title: "Sintra palaces", stayId: "hotel-alfama", route: { kind: "side", placeIds: ["lisbon", "sintra", "lisbon"] } } },
        { op: "set_meta", meta: { intro: "Tiles, trams and custard tarts." } },
      ],
    });
    expect(response.status).toBe(200);
    const { trip: updated } = await response.json();
    expect(updated.revision).toBe(1);
    expect(updated.document.days.map((day: { id: string }) => day.id)).toEqual(["day-1", "day-2"]);
    expect(updated.document).toMatchObject({ intro: "Tiles, trams and custard tarts.", timeZone: "Europe/Lisbon", currency: "EUR" });
    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, trip.id));
    expect(row.summary).toBe("Tiles, trams and custard tarts.");
    expect(row.contentText).toContain("Stay: Memmo Alfama");

    // An operation that would leave a dangling id changes nothing.
    const invalid = await operations(trip.id, { operations: [{ op: "upsert_day", day: { id: "day-3", date: "2026-11-08", title: "Belém", stayId: "nowhere" } }] });
    expect(invalid.status).toBe(422);
    expect((await invalid.json()).error.code).toBe("TRIP_INVALID");
    expect((await storedTrip(trip.id)).revision).toBe(1);

    const stale = await operations(trip.id, { revision: 0, operations: [{ op: "delete", collection: "days", id: "day-2" }] });
    expect(stale.status).toBe(409);

    // Without a revision they apply to the latest document.
    const latest = await operations(trip.id, { operations: [{ op: "delete", collection: "hotels", id: "hotel-alfama" }] });
    expect((await latest.json()).trip).toMatchObject({ revision: 2, document: { hotels: [], days: [{ stayId: null }, { stayId: null }] } });
  });

  it("deletes a trip with its document", async () => {
    const trip = await create();
    expect((await tripRoute.DELETE(apiRequest("DELETE", `/api/v1/trips/${trip.id}`, { token: env.tokens.bob }), params({ id: trip.id }))).status).toBe(404);
    expect((await tripRoute.DELETE(apiRequest("DELETE", `/api/v1/trips/${trip.id}`, { token: env.tokens.alice }), params({ id: trip.id }))).status).toBe(204);
    expect(await storedTrip(trip.id)).toBeUndefined();
    expect((await get(trip.id)).status).toBe(404);

    // Deleting it as a summary removes the document too.
    const other = await create();
    expect((await summaryRoute.DELETE(apiRequest("DELETE", `/api/v1/summaries/${other.id}`, { token: env.tokens.alice }), params({ id: other.id }))).status).toBe(204);
    expect(await storedTrip(other.id)).toBeUndefined();
  });
});

describe("/api/v1/trips/:id/ingest", () => {
  const device = { installationId: "f6daa60d-d123-47a2-8512-596ffb2a9872", token: "a".repeat(64), environment: "sandbox", platform: "ios" };
  const booking = { source: { type: "text", text: "Booking confirmed: Memmo Alfama, 6–9 November 2026, confirmation MA-5521, total €540.", title: "Memmo Alfama booking" }, instructions: "Add the hotel" };

  function billing(reserve: () => Response) {
    vi.stubEnv("RX_SUBSCRIPTION_URL", "https://subscription.test");
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "sandbox");
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_sandbox_test-secret");
    vi.stubEnv("RX_SUBSCRIPTION_SANDBOX_API_KEY", "");
    vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_API_KEY", "");
    const fetch = vi.fn<(url: unknown, init?: RequestInit) => Promise<Response>>(async (url) => {
      const path = new URL(String(url)).pathname;
      if (path === "/api/v1/balances/reserve") return reserve();
      if (path === "/api/v1/balances/reservations/res-trip/settle") return Response.json({ operationShortfallAmount: 0, status: "closed" });
      throw new Error(`Unexpected ${path}`);
    });
    vi.stubGlobal("fetch", fetch);
    return fetch;
  }
  const bodies = (fetch: ReturnType<typeof billing>, path: string) => fetch.mock.calls
    .filter(([url]) => new URL(String(url)).pathname === path)
    .map(([, init]) => JSON.parse(init?.body as string));

  it("queues the trip agent, applies its operations, charges points and pushes \"Trip updated\"", async () => {
    expect((await devicesRoute.POST(apiRequest("POST", "/api/v1/devices", { token: env.tokens.alice, body: device }))).status).toBe(204);
    const trip = await create();
    env.ai.tripAgent = (input) => ({
      operations: [
        { op: "upsert_hotel", hotel: { id: "hotel-memmo-alfama", name: "Memmo Alfama", placeId: "lisbon", address: null, checkIn: "2026-11-06", checkOut: "2026-11-09", checkInTime: null, confirmation: "MA-5521", price: { amount: 540, currency: "EUR" }, url: null, status: "booked" } },
        { op: "upsert_day", day: { ...input.document.days[0], stayId: "hotel-memmo-alfama" } },
        // Dropped: references a place that doesn't exist.
        { op: "upsert_hotel", hotel: { id: "hotel-ghost", name: "Ghost", placeId: "atlantis", address: null, checkIn: "2026-11-06", checkOut: "2026-11-07", checkInTime: null, confirmation: null, price: null, url: null, status: "idea" } },
      ],
      changeSummary: "Booked Memmo Alfama for 6–9 November.",
    });
    const fetch = billing(() => Response.json({ reservationId: "res-trip", amount: 1, available: 9 }));

    const response = await ingest(trip.id, booking);
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ status: "queued" });

    await vi.waitFor(async () => expect((await storedTrip(trip.id)).revision).toBe(1));
    const stored = await storedTrip(trip.id);
    expect(stored.document.hotels.map((hotel) => hotel.id)).toEqual(["hotel-memmo-alfama"]);
    expect(stored.document.days[0].stayId).toBe("hotel-memmo-alfama");
    expect(env.ai.calls.updateTrip[0]).toMatchObject({ instructions: "Add the hotel", source: { title: "Memmo Alfama booking" } });
    expect(env.ai.calls.updateTrip[0].source.text).toContain("MA-5521");

    await vi.waitFor(() => expect(sendPush).toHaveBeenCalledTimes(1));
    expect(sendPush).toHaveBeenCalledWith(expect.objectContaining({ token: device.token }), {
      aps: { alert: { title: "Trip updated", body: "Lisbon long weekend: Booked Memmo Alfama for 6–9 November." }, sound: "default" },
      summaryId: trip.id,
      tripId: trip.id,
      userId: "user-alice",
    });

    await vi.waitFor(() => expect(bodies(fetch, "/api/v1/balances/reservations/res-trip/settle")).toHaveLength(1));
    const [reserve] = bodies(fetch, "/api/v1/balances/reserve");
    expect(reserve).toMatchObject({ rxlabUserId: "user-alice", unit: "points", amount: 1, metadata: { tripId: trip.id } });
    expect(reserve.idempotencyKey).toMatch(/^trip:/);
    // One mock step of 10 input + 10 output tokens at $0.01/$0.04 = $0.50 → 25 points.
    expect(bodies(fetch, "/api/v1/balances/reservations/res-trip/settle")[0]).toMatchObject({ amount: 25, metadata: { outcome: "finished", tripId: trip.id } });
  });

  it("refuses an empty balance with 402 before queueing anything", async () => {
    const trip = await create();
    billing(() => Response.json({ error: "insufficient_balance", available: 0, required: 1 }, { status: 409 }));
    const response = await ingest(trip.id, booking);
    expect(response.status).toBe(402);
    expect((await response.json()).error.code).toBe("TRIP_POINTS_EXHAUSTED");
    expect(env.ai.calls.updateTrip).toHaveLength(0);
  });

  it("only takes the owner's trips", async () => {
    const trip = await create();
    expect((await ingest(trip.id, booking, env.tokens.bob)).status).toBe(404);
    expect((await ingest("missing", booking)).status).toBe(404);
    expect((await ingest(trip.id, { source: { type: "text", text: " " } })).status).toBe(400);
  });

  it("leaves the trip alone when the agent fails, settling the hold as failed", async () => {
    const trip = await create();
    env.ai.tripAgent = () => null;
    const fetch = billing(() => Response.json({ reservationId: "res-trip", amount: 1, available: 9 }));
    expect((await ingest(trip.id, booking)).status).toBe(202);
    await vi.waitFor(() => expect(bodies(fetch, "/api/v1/balances/reservations/res-trip/settle")).toHaveLength(1));
    expect(bodies(fetch, "/api/v1/balances/reservations/res-trip/settle")[0]).toMatchObject({ metadata: { outcome: "failed" } });
    expect((await storedTrip(trip.id)).revision).toBe(0);
    expect(sendPush).not.toHaveBeenCalled();
  });
});

describe("trip chat", () => {
  it("streams the owner's trip chat and refuses other people's trips", async () => {
    const trip = await create();
    const ask = (token: string) => chatRoute.POST(apiRequest("POST", "/api/v1/chat", {
      token, body: { tripId: trip.id, messages: [{ id: "1", role: "user", parts: [{ type: "text", text: "what is on day 1?" }] }] },
    }));
    const response = await ask(env.tokens.alice);
    expect(response.status).toBe(200);
    expect((await response.text()).trim().endsWith("data: [DONE]")).toBe(true);
    expect((await ask(env.tokens.bob)).status).toBe(404);
  });

  it("edits the trip with updateTrip, sending an invalid change back once before keeping what fits", async () => {
    const trip = await create();
    const { updateTrip } = tripChatTools(env.handle.db, "user-alice", trip.id, env.ai);
    const call = (input: unknown) => updateTrip.execute!(input as never, { toolCallId: "call", messages: [], context: {} } as never);
    const hotel = { op: "upsert_hotel", hotel: { id: "hotel-alfama", name: "Memmo Alfama", placeId: "lisbon", checkIn: "2026-11-06", checkOut: "2026-11-09", status: "booked" } };
    const dangling = { op: "upsert_day", day: { id: "day-2", date: "2026-11-07", title: "Belém", stayId: "nowhere" } };

    const refused = await call({ operations: [hotel, dangling], changeSummary: "Added the hotel" });
    expect(refused).toMatchObject({ error: expect.any(String), issues: expect.any(Array) });
    expect((await storedTrip(trip.id)).revision).toBe(0);

    const kept = await call({ operations: [hotel, dangling], changeSummary: "Added the hotel" });
    expect(kept).toMatchObject({ applied: 1, revision: 1, changeSummary: "Added the hotel" });
    const stored = await storedTrip(trip.id);
    expect(stored.document.hotels.map((h) => h.id)).toEqual(["hotel-alfama"]);
    expect(stored.document.days.map((d) => d.id)).toEqual(["day-1"]);
  });
});
