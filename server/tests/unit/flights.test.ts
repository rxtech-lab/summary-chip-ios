import { describe, expect, it } from "vitest";
import { AeroDataBoxProvider, normalizeAeroDataBox } from "@/lib/flights/aerodatabox";
import { detectFlightEvents, flightAlertText } from "@/lib/flights/changes";
import { flightContentState } from "@/lib/flights/live-activity";
import { MockFlightProvider } from "@/lib/flights/mock";
import type { ProviderFlight } from "@/lib/flights/provider";
import { DAY, HOUR, MINUTE, planNextCheck, type TrackedFlight } from "@/lib/flights/schedule";
import { parseFlightNumber, trackedSegments } from "@/lib/services/flights";
import { tripDocumentSchema } from "@/lib/contracts/trip";

const departure = Date.parse("2026-10-12T01:00:00Z");
const arrival = Date.parse("2026-10-12T05:30:00Z");
const found = (overrides: Partial<TrackedFlight> = {}): TrackedFlight => ({
  state: "found", date: "2026-10-12", status: "scheduled", departureAt: departure, arrivalAt: arrival, landedAt: null, ...overrides,
});

async function baseFlight(): Promise<ProviderFlight> {
  return (await new MockFlightProvider().lookup({ flightNumber: "CX520", date: "2026-10-12" }))[0];
}

describe("flight numbers", () => {
  it("normalizes spacing, case and leading zeros", () => {
    expect(parseFlightNumber("cx 0520")).toEqual({ code: "CX520", display: "CX 520" });
    expect(parseFlightNumber("NH-12a")).toEqual({ code: "NH12A", display: "NH 12A" });
    expect(parseFlightNumber("3K 761")).toEqual({ code: "3K761", display: "3K 761" });
    expect(parseFlightNumber("hello")).toBeNull();
    expect(parseFlightNumber("12 345")).toBeNull();
  });

  it("tracks flight segments of the chosen option of transports that aren't ideas", () => {
    const segment = (number: string) => ({ mode: "flight", fromName: "HKG", toName: "NRT", departure: "2026-10-12T09:00", flight: { flightNumber: number } });
    const document = tripDocumentSchema.parse({
      title: "Tokyo", startDate: "2026-10-12", endDate: "2026-10-15",
      transports: [
        { id: "out", date: "2026-10-12", label: "Out", status: "booked", options: [{ id: "a", label: "CX", segments: [segment("CX 520")] }] },
        { id: "idea", date: "2026-10-13", label: "Maybe", status: "idea", options: [{ id: "b", label: "JL", segments: [segment("JL 1")] }] },
        { id: "two", date: "2026-10-15", label: "Back", options: [{ id: "c", label: "NH", segments: [segment("NH 2")] }, { id: "d", label: "JL", segments: [segment("JL 3")] }], selectedOptionId: "d" },
      ],
    });
    expect(trackedSegments(document)).toEqual([
      { transportId: "out", optionId: "a", segmentIndex: 0, code: "CX520", display: "CX 520", date: "2026-10-12" },
      { transportId: "two", optionId: "d", segmentIndex: 0, code: "JL3", display: "JL 3", date: "2026-10-12" },
    ]);
  });
});

describe("polling schedule", () => {
  it("checks rarely far out and often close to departure", () => {
    expect(planNextCheck(found(), departure - 10 * DAY)).toEqual({ done: false, nextAt: departure - 9 * DAY });
    expect(planNextCheck(found(), departure - 2 * DAY).nextAt).toBe(departure - 2 * DAY + 6 * HOUR);
    expect(planNextCheck(found(), departure - 10 * HOUR).nextAt).toBe(departure - 9 * HOUR);
    expect(planNextCheck(found(), departure - 2 * HOUR).nextAt).toBe(departure - 2 * HOUR + 10 * MINUTE);
  });

  it("wakes exactly when the Live Activity window opens", () => {
    expect(planNextCheck(found(), departure - 4 * HOUR - 20 * MINUTE).nextAt).toBe(departure - 4 * HOUR);
  });

  it("polls in the air, faster near arrival", () => {
    expect(planNextCheck(found({ status: "en_route" }), arrival - 2 * HOUR).nextAt).toBe(arrival - 2 * HOUR + 15 * MINUTE);
    expect(planNextCheck(found({ status: "approaching" }), arrival - 30 * MINUTE).nextAt).toBe(arrival - 25 * MINUTE);
  });

  it("stops 15 minutes after landing", () => {
    const landed = found({ status: "landed", landedAt: arrival });
    expect(planNextCheck(landed, arrival + 12 * MINUTE)).toEqual({ done: false, nextAt: arrival + 15 * MINUTE });
    expect(planNextCheck(landed, arrival + 15 * MINUTE).done).toBe(true);
  });

  it("stops for cancellations, past unknown flights and flights never reported landed", () => {
    expect(planNextCheck(found({ status: "cancelled" }), departure).done).toBe(true);
    expect(planNextCheck(found({ state: "not_found" }), departure + 3 * DAY).done).toBe(true);
    expect(planNextCheck(found({ state: "not_found" }), departure - 10 * DAY).nextAt).toBe(departure - 9 * DAY);
    expect(planNextCheck(found({ status: "en_route" }), arrival + 13 * HOUR).done).toBe(true);
  });
});

describe("flight events", () => {
  it("announces a delay once, and again only when it moves by 15 minutes", async () => {
    const before = await baseFlight();
    const delayed = structuredClone(before);
    delayed.departure.estimated = "2026-10-12T01:30:00.000Z";
    delayed.departure.estimatedLocal = "2026-10-12T09:30";
    const first = detectFlightEvents(before, delayed, null);
    expect(first.events).toEqual([{ kind: "time_change", delayMinutes: 30, departsLocal: "2026-10-12T09:30" }]);
    expect(first.alertState).toEqual({ delayMinutes: 30 });
    const slightly = structuredClone(delayed);
    slightly.departure.estimated = "2026-10-12T01:40:00.000Z";
    expect(detectFlightEvents(delayed, slightly, first.alertState).events).toEqual([]);
    expect(flightAlertText(first.events[0], delayed, "en")).toEqual({ title: "CX 520 delayed", body: "Now departs 09:30 (+30 min) from HKG" });
    expect(flightAlertText(first.events[0], delayed, "zh-Hant").title).toBe("CX 520 延誤");
  });

  it("reports gates, boarding, departure, landing with the belt, and cancellation", async () => {
    const before = await baseFlight();
    const gate = structuredClone(before);
    gate.departure.gate = "B12";
    gate.status = "boarding";
    expect(detectFlightEvents(before, gate, null).events.map((event) => event.kind)).toEqual(["gate", "boarding"]);
    const airborne: ProviderFlight = { ...structuredClone(gate), status: "en_route" };
    expect(detectFlightEvents(gate, airborne, null).events).toEqual([{ kind: "departed" }]);
    const landed = structuredClone(airborne);
    landed.status = "landed";
    landed.arrival.baggageBelt = "7";
    expect(detectFlightEvents(airborne, landed, null).events).toEqual([{ kind: "landed", gate: null, belt: "7" }]);
    expect(detectFlightEvents(before, { ...before, status: "cancelled" }, null).events).toEqual([{ kind: "cancelled" }]);
  });

  it("builds the Live Activity state in Unix seconds", async () => {
    const state = flightContentState(await baseFlight(), departure - HOUR);
    expect(state).toMatchObject({ status: "scheduled", departureScheduled: departure / 1000, arrivalBest: arrival / 1000, delayMinutes: 0, departureTerminal: "1" });
  });
});

describe("AeroDataBox", () => {
  const raw = {
    number: "CX 520", status: "Departed", codeshareStatus: "IsOperator",
    airline: { name: "Cathay Pacific", iata: "CX", icao: "CPA" },
    aircraft: { model: "Airbus A350-900" },
    departure: {
      airport: { iata: "HKG", icao: "VHHH", name: "Hong Kong Chek Lap Kok", shortName: "Hong Kong", municipalityName: "Hong Kong", timeZone: "Asia/Hong_Kong", location: { lat: 22.3, lon: 113.9 } },
      scheduledTime: { utc: "2026-10-12 01:00Z", local: "2026-10-12 09:00+08:00" },
      revisedTime: { utc: "2026-10-12 01:20Z", local: "2026-10-12 09:20+08:00" },
      runwayTime: { utc: "2026-10-12 01:31Z", local: "2026-10-12 09:31+08:00" },
      terminal: "1", gate: "B12",
    },
    arrival: {
      airport: { iata: "NRT", name: "Tokyo Narita", timeZone: "Asia/Tokyo" },
      scheduledTime: { utc: "2026-10-12 05:30Z", local: "2026-10-12 14:30+09:00" },
      predictedTime: { utc: "2026-10-12 05:45Z", local: "2026-10-12 14:45+09:00" },
      terminal: "2", baggageBelt: "7",
    },
  };

  it("normalizes a flight", () => {
    const flight = normalizeAeroDataBox(raw);
    expect(flight).toMatchObject({ flightNumber: "CX 520", status: "departed", airline: { name: "Cathay Pacific", iata: "CX" }, aircraft: "Airbus A350-900" });
    expect(flight.departure).toMatchObject({ iata: "HKG", name: "Hong Kong", scheduled: "2026-10-12T01:00:00.000Z", estimated: "2026-10-12T01:20:00.000Z", actual: "2026-10-12T01:31:00.000Z", actualLocal: "2026-10-12T09:31", gate: "B12", baggageBelt: null, coordinate: { lat: 22.3, lng: 113.9 } });
    expect(flight.arrival).toMatchObject({ estimatedLocal: "2026-10-12T14:45", actual: null, baggageBelt: "7" });
  });

  it("calls RapidAPI and reads 204 as no flight", async () => {
    const calls: string[] = [];
    const provider = new AeroDataBoxProvider({
      key: "key", host: "adb.test",
      fetch: async (input, init) => {
        calls.push(String(input));
        expect(new Headers(init?.headers).get("x-rapidapi-key")).toBe("key");
        return String(input).includes("XX1") ? new Response(null, { status: 204 }) : Response.json([{ ...raw, codeshareStatus: "IsCodeshared", number: "BA 1" }, raw]);
      },
    });
    expect((await provider.lookup({ flightNumber: "CX520", date: "2026-10-12" }))[0].flightNumber).toBe("CX 520");
    expect(calls[0]).toBe("https://adb.test/flights/number/CX520/2026-10-12?withAircraftImage=false&withLocation=false&dateLocalRole=Departure");
    expect(await provider.lookup({ flightNumber: "XX1", date: "2026-10-12" })).toEqual([]);
  });

  it("reports rate limits as a provider failure to retry", async () => {
    const provider = new AeroDataBoxProvider({ key: "key", fetch: async () => new Response(null, { status: 429, headers: { "retry-after": "120" } }) });
    await expect(provider.lookup({ flightNumber: "CX520", date: "2026-10-12" })).rejects.toMatchObject({ name: "FlightProviderError", retryAfterMs: 120_000 });
  });
});
