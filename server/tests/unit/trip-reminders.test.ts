import { describe, expect, it } from "vitest";
import { tripDocumentSchema } from "@/lib/contracts/trip";
import { tripReminderPayload } from "@/lib/services/notifications";
import { activeTripDocument } from "@/lib/services/trip-document";
import { tripReminders } from "@/lib/trips/reminders";

const document = tripDocumentSchema.parse({
  title: "Kyoto weekend", startDate: "2030-04-01", endDate: "2030-04-03", timeZone: "Asia/Tokyo",
  days: [{ id: "d1", date: "2030-04-01", title: "Arrive", moments: [{ slot: "evening", time: "18:00", text: "Dinner" }] }],
  transports: [{ id: "train", date: "2030-04-01", label: "Airport to Kyoto", selectedOptionId: "chosen", options: [
    { id: "unused", label: "Unused", departure: "2030-04-01T08:00" },
    { id: "chosen", label: "Haruka", departure: "2030-04-01T09:00", segments: [
      { mode: "train", fromName: "Airport", toName: "Osaka" },
      { mode: "train", fromName: "Osaka", toName: "Kyoto", departure: "2030-04-01T09:45" },
      { mode: "walk", fromName: "Station", toName: "Hotel" },
    ] },
  ] }],
});

describe("trip reminder schedule", () => {
  it("sends a brief itinerary at 20:00 the previous local day, only on planned dates", () => {
    const daily = tripReminders(document).filter((event) => event.kind === "day");
    expect(daily).toHaveLength(1);
    expect(daily[0]).toMatchObject({ at: Date.parse("2030-03-31T11:00:00Z"), until: Date.parse("2030-03-31T15:00:00Z") });
    expect(daily[0].detail).toBe("2030-04-01 · Arrive · 09:00 Airport to Kyoto · 18:00 Dinner");
  });

  it("reminds each timed segment of the chosen option and never invents a later leg's departure", () => {
    const legs = tripReminders(document).filter((event) => event.kind === "leg");
    expect(legs.map((leg) => leg.at)).toEqual([Date.parse("2030-04-01T00:00:00Z"), Date.parse("2030-04-01T00:45:00Z")]);
    expect(legs.map((leg) => leg.detail)).toEqual(["09:00 Airport → Osaka", "09:45 Osaka → Kyoto"]);
    expect(legs[0].until - legs[0].at).toBe(10 * 60_000);
  });

  it("uses the first option by default, handles a transport without segments, and skips ideas", () => {
    const trip = structuredClone(document);
    trip.transports[0].selectedOptionId = null;
    expect(tripReminders(trip).filter((event) => event.kind === "leg")).toMatchObject([{ detail: "08:00 Airport to Kyoto · Unused" }]);
    trip.transports[0].status = "idea";
    expect(tripReminders(trip).filter((event) => event.kind === "leg")).toEqual([]);
  });

  it("resolves wall-clock times across a DST change without subtracting a fixed 24 hours", () => {
    const trip = structuredClone(document);
    trip.timeZone = "America/New_York";
    trip.startDate = trip.endDate = trip.days[0].date = trip.transports[0].date = "2026-11-01";
    trip.transports[0].options[1].departure = "2026-11-01T09:00";
    trip.transports[0].options[1].segments = [];
    const events = tripReminders(trip);
    expect(events[0].at).toBe(Date.parse("2026-11-01T00:00:00Z"));
    expect(events[1].at).toBe(Date.parse("2026-11-01T14:00:00Z"));
  });

  it("filters plan alternatives for each reader and keeps keys stable when departure clocks change", () => {
    const trip = structuredClone(document);
    trip.plans = [{ id: "route", title: "Route", scope: "trip", options: [{ id: "a", label: "A" }, { id: "b", label: "B" }] }];
    trip.transports[0].planOptionId = "a";
    expect(tripReminders(activeTripDocument(trip, { route: "b" })).filter((event) => event.kind === "leg")).toEqual([]);
    const before = tripReminders(trip).filter((event) => event.kind === "leg")[0];
    trip.transports[0].options[1].departure = "2030-04-01T10:00";
    const after = tripReminders(trip).filter((event) => event.kind === "leg").find((event) => event.key === before.key)!;
    expect(after.at - before.at).toBe(60 * 60_000);
  });

  it("localizes the heading, routes to the recipient's trip and bounds lock-screen text", () => {
    const payload = tripReminderPayload("bob", "trip", "🚆".repeat(100), { ...tripReminders(document)[0], detail: "旅程".repeat(300) }, "zh-Hant");
    expect(payload).toMatchObject({ userId: "bob", summaryId: "trip", tripId: "trip", aps: { alert: { title: "明日行程" }, sound: "default" } });
    expect([...payload.aps.alert.body]).toHaveLength(180);
    expect(payload.aps.alert.body).not.toContain("\uFFFD");
  });
});
