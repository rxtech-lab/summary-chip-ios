import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { tripDocumentSchema, tripIntegrityIssues, tripOperationSchema, type TripDocument } from "@/lib/contracts/trip";
import { parseOperations } from "@/lib/ai/trip-agent";
import { activeTripDocument, applyOperations, selectedPlanOptionId, tripDigest, tripText } from "@/lib/services/trip-document";
import { applicableOperations } from "@/lib/services/trips";

const fixture = JSON.parse(readFileSync(new URL("../fixtures/northbound-trip.json", import.meta.url), "utf8"));

function minimal(): TripDocument {
  return tripDocumentSchema.parse({
    title: "Kyoto weekend",
    startDate: "2026-11-06",
    endDate: "2026-11-08",
    timeZone: "Asia/Tokyo",
    currency: "JPY",
    places: [
      { id: "kyoto", name: "Kyoto", kind: "city", coordinate: { lat: 35.0116, lng: 135.7681 }, major: true },
      { id: "kix", name: "Kansai Airport", kind: "airport", coordinate: { lat: 34.4347, lng: 135.244 } },
    ],
    days: [
      { id: "day-1", date: "2026-11-06", title: "Arrive", route: { kind: "airport", placeIds: ["kix", "kyoto"] }, moments: [{ slot: "evening", text: "Check in", placeId: "kyoto" }], stayId: "ryokan", transportIds: ["haruka"] },
    ],
    transports: [
      {
        id: "haruka", date: "2026-11-06", label: "KIX → Kyoto", options: [{
          id: "haruka-1", label: "Haruka", departure: "2026-11-06T15:16", arrival: "2026-11-06T16:35",
          segments: [{ mode: "train", fromPlaceId: "kix", toPlaceId: "kyoto", fromName: "Kansai Airport", toName: "Kyoto", train: { name: "Haruka", number: "36", category: "limited_express" } }],
        }],
      },
    ],
    hotels: [{ id: "ryokan", name: "Ryokan Yachiyo", placeId: "kyoto", checkIn: "2026-11-06", checkOut: "2026-11-08" }],
    expenses: [{ id: "haruka-fare", category: "transport", title: "Haruka", amount: { amount: 3640, currency: "JPY" }, linkedId: "haruka", dayId: "day-1" }],
  });
}

describe("TripDocument", () => {
  it("parses the converted Northbound trip", () => {
    const parsed = tripDocumentSchema.safeParse(fixture);
    expect(parsed.error?.issues).toBeUndefined();
    const doc = parsed.data!;
    expect(doc).toMatchObject({ version: 1, startDate: "2026-10-10", endDate: "2026-10-20", timeZone: "Asia/Tokyo", currency: "JPY" });
    expect(doc.days).toHaveLength(11);
    expect(doc.days[2]).toMatchObject({ id: "day-3", date: "2026-10-12", stayId: "stay-sendai-1012", transportIds: ["oct12-tokyo-sendai"] });
    expect(doc.days[2].moments.map((moment) => moment.slot)).toEqual(["morning", "afternoon", "evening"]);
    const local = doc.transports.find((transport) => transport.id === "oct12-tokyo-sendai")!.options[0];
    expect(local.segments[0]).toMatchObject({ departure: "2026-10-12T05:53", train: { number: "544F", category: "rapid" } });
    const hayabusa = doc.transports.flatMap((transport) => transport.options).flatMap((option) => option.segments).find((segment) => segment.train?.name === "はやぶさ");
    expect(hayabusa?.train?.category).toBe("shinkansen");
    const pass = doc.expenses.find((expense) => expense.category === "pass")!;
    expect(doc.expenses.filter((expense) => expense.coveredByExpenseId === pass.id).length).toBeGreaterThan(0);
    expect(tripIntegrityIssues(doc)).toEqual([]);
  });

  it("fills defaults and keeps nullable fields", () => {
    const doc = tripDocumentSchema.parse({ title: "T", startDate: "2026-01-01", endDate: "2026-01-02" });
    expect(doc).toMatchObject({ version: 1, timeZone: "UTC", currency: "USD", places: [], days: [], sources: [] });
  });

  it("reports dangling and duplicate ids, and inverted dates", () => {
    const doc = minimal();
    const broken: TripDocument = {
      ...doc,
      endDate: "2026-11-01",
      places: [...doc.places, { ...doc.places[0] }],
      days: [{ ...doc.days[0], stayId: "nowhere", transportIds: ["ghost"], route: { kind: "out", placeIds: ["atlantis"] } }],
      expenses: [{ ...doc.expenses[0], coveredByExpenseId: "haruka-fare" }],
    };
    const messages = tripIntegrityIssues(broken).map((issue) => `${issue.path.join(".")}: ${issue.message}`);
    expect(messages).toEqual(expect.arrayContaining([
      "endDate: must not be before startDate",
      "places.2.id: duplicate id \"kyoto\"",
      "days.0.route.placeIds.0: unknown id \"atlantis\"",
      "days.0.stayId: unknown id \"nowhere\"",
      "days.0.transportIds.0: unknown id \"ghost\"",
      "expenses.0.coveredByExpenseId: unknown id \"haruka-fare\"",
    ]));
    expect(tripDocumentSchema.safeParse(broken).success).toBe(false);
  });

  it("validates formats", () => {
    expect(tripDocumentSchema.safeParse({ title: "T", startDate: "2026/01/01", endDate: "2026-01-02" }).success).toBe(false);
    const op = tripOperationSchema.safeParse({ op: "upsert_transport", transport: { id: "x", date: "2026-01-01", label: "x", options: [{ id: "o", label: "o", departure: "05:53" }] } });
    expect(op.success).toBe(false);
  });
});

describe("applyOperations", () => {
  it("upserts by id, keeps days sorted and leaves the input alone", () => {
    const doc = minimal();
    const next = applyOperations(doc, tripOperationSchema.array().parse([
      { op: "upsert_day", day: { id: "day-3", date: "2026-11-08", title: "Leave" } },
      { op: "upsert_day", day: { id: "day-2", date: "2026-11-07", title: "Fushimi Inari", stayId: "ryokan" } },
      { op: "upsert_place", place: { id: "kyoto", name: "Kyoto City", kind: "city", coordinate: { lat: 35.01, lng: 135.77 } } },
      { op: "add_source", source: { title: "Haruka", url: "https://www.westjr.co.jp/global/en/ticket/haruka/" } },
      { op: "add_source", source: { title: "Haruka again", url: "https://www.westjr.co.jp/global/en/ticket/haruka/" } },
    ]));
    expect(next.days.map((day) => day.id)).toEqual(["day-1", "day-2", "day-3"]);
    expect(next.places.find((place) => place.id === "kyoto")?.name).toBe("Kyoto City");
    expect(next.places).toHaveLength(2);
    expect(next.sources).toHaveLength(1);
    expect(doc.days).toHaveLength(1);
    expect(tripDocumentSchema.safeParse(next).success).toBe(true);
  });

  it("deletes records and clears references to them", () => {
    const doc = minimal();
    const next = applyOperations(doc, [
      { op: "delete", collection: "hotels", id: "ryokan" },
      { op: "delete", collection: "transports", id: "haruka" },
      { op: "delete", collection: "places", id: "kix" },
      { op: "delete", collection: "notes", id: "missing" },
    ]);
    expect(next.hotels).toEqual([]);
    expect(next.days[0]).toMatchObject({ stayId: null, transportIds: [], route: { placeIds: ["kyoto"] } });
    expect(next.expenses[0].linkedId).toBeNull();
    expect(tripIntegrityIssues(next)).toEqual([]);
  });

  it("set_meta changes only the given fields", () => {
    const doc = minimal();
    const [op] = parseOperations([{ op: "set_meta", meta: { title: "Kyoto long weekend", subtitle: null } }]).operations;
    const next = applyOperations(doc, [op]);
    expect(next).toMatchObject({ title: "Kyoto long weekend", subtitle: null, timeZone: "Asia/Tokyo", currency: "JPY", startDate: "2026-11-06" });
  });

  it("drops malformed and dangling operations from the agent", () => {
    const { operations, rejected } = parseOperations([
      { op: "upsert_note", note: { id: "n1", title: "Note", text: "Bring cash" } },
      { op: "upsert_hotel", hotel: { id: "h2" } },
      { op: "teleport" },
    ]);
    expect(operations).toHaveLength(1);
    expect(rejected.map((item) => item.index)).toEqual([1, 2]);

    const dangling = tripOperationSchema.parse({ op: "upsert_day", day: { id: "day-2", date: "2026-11-07", title: "Nara", stayId: "no-such-hotel" } });
    const result = applicableOperations(minimal(), [...operations, dangling]);
    expect(result.operations).toEqual(operations);
    expect(result.document.notes.map((note) => note.id)).toEqual(["n1"]);
  });

  it("derives the summary card and search text", () => {
    const digest = tripDigest(minimal());
    expect(digest).toMatchObject({ title: "Kyoto weekend", highlights: ["Arrive"], keywords: ["Kyoto"] });
    expect(digest.summary).toContain("3-day trip");
    const text = tripText(minimal());
    expect(text).toContain("Day 1 · 2026-11-06 · Arrive");
    expect(text).toContain("Stay: Ryokan Yachiyo");
    expect(text).toContain("train: Kansai Airport → Kyoto · Haruka 36");
  });

  it("validates custom views and keeps them through edits", () => {
    const view = {
      id: "fares",
      title: "Pass vs IC",
      dayId: "day-1",
      spec: {
        root: "root",
        elements: {
          root: { type: "Stack", children: ["heading", "table"] },
          heading: { type: "Heading", props: { text: "Fares" } },
          table: {
            type: "Table",
            props: {
              columns: [{ key: "route", label: "Route" }, { key: "ic", label: "IC", format: "money", total: true }],
              rows: [{ cells: { route: "KIX → Kyoto", ic: { value: 3640, detail: "IC" } } }],
            },
          },
        },
      },
    };
    const [op] = parseOperations([{ op: "upsert_view", view }]).operations;
    const next = tripDocumentSchema.parse(applyOperations(minimal(), [op]));
    expect(next.views).toHaveLength(1);
    expect(next.views[0].spec.elements.root).toMatchObject({ type: "Stack", props: {}, children: ["heading", "table"] });
    expect(tripText(next)).toContain("KIX → Kyoto | 3640");

    // Deleting the day moves its view to the trip's Views section.
    const withoutDay = applyOperations(next, [{ op: "delete", collection: "days", id: "day-1" }]);
    expect(withoutDay.views[0].dayId).toBeNull();
    expect(applyOperations(next, [{ op: "delete", collection: "views", id: "fares" }]).views).toEqual([]);
  });

  it("refuses views with unknown components, missing children, reuse or cycles", () => {
    const withSpec = (elements: Record<string, unknown>) => ({ ...minimal(), views: [{ id: "v", title: "V", spec: { root: "root", elements } }] });
    expect(tripDocumentSchema.safeParse(withSpec({ root: { type: "Marquee", props: {} } })).success).toBe(false);
    expect(tripDocumentSchema.safeParse(withSpec({ root: { type: "Text", props: { text: "hi" }, children: ["x"] } })).success).toBe(false);
    const issues = (elements: Record<string, unknown>) =>
      tripIntegrityIssues(withSpec(elements) as TripDocument).map((issue) => issue.message);
    expect(issues({ root: { type: "Stack", props: {}, children: ["ghost"] } })).toEqual(['unknown element "ghost"']);
    expect(issues({ root: { type: "Stack", props: {}, children: ["a", "a"] }, a: { type: "Divider", props: {} } })).toEqual(['element "a" is used more than once']);
    expect(issues({ root: { type: "Card", props: {}, children: ["b"] }, b: { type: "Card", props: {}, children: ["root"] } })).toEqual(['element "root" is used more than once']);
  });

  it("builds the JR pass vs IC card comparison for the Northbound trip", () => {
    const doc = tripDocumentSchema.parse(fixture);
    const comparison = doc.views.find((view) => view.id === "view-jr-pass-vs-ic");
    expect(comparison?.dayId).toBeNull();
    expect(comparison?.spec.elements["stat-pass"]).toMatchObject({ props: { value: 53020 } });
    expect(comparison?.spec.elements["stat-ic"]).toMatchObject({ props: { value: 48440 } });
    expect(doc.views.find((view) => view.id === "view-pass-day-1")?.dayId).toBe("day-5");
  });
});

describe("plans", () => {
  /** Day 2 has two routes, and route 2 brings its own hotel and transport. */
  function planned(): TripDocument {
    const doc = minimal();
    return tripDocumentSchema.parse({
      ...doc,
      places: [...doc.places, { id: "nara", name: "Nara", kind: "city", coordinate: { lat: 34.6851, lng: 135.8048 } }],
      days: [
        ...doc.days,
        { id: "day-2-arashiyama", date: "2026-11-07", title: "Arashiyama", planOptionId: "route-1", route: { kind: "side", placeIds: ["kyoto"] } },
        { id: "day-2-nara", date: "2026-11-07", title: "Nara deer", planOptionId: "route-2", route: { kind: "side", placeIds: ["kyoto", "nara"] }, stayId: "nara-inn", transportIds: ["kintetsu"] },
      ],
      transports: [...doc.transports, {
        id: "kintetsu", date: "2026-11-07", label: "Kyoto → Nara", planOptionId: "route-2",
        options: [{ id: "kintetsu-1", label: "Kintetsu", segments: [{ mode: "train", fromPlaceId: "kyoto", toPlaceId: "nara", fromName: "Kyoto", toName: "Nara" }] }],
      }],
      hotels: [...doc.hotels, { id: "nara-inn", name: "Nara inn", placeId: "nara", checkIn: "2026-11-07", checkOut: "2026-11-08", planOptionId: "route-2" }],
      expenses: [...doc.expenses, { id: "kintetsu-fare", category: "transport", title: "Kintetsu", amount: { amount: 760, currency: "JPY" }, linkedId: "kintetsu", dayId: "day-2-nara", planOptionId: "route-2" }],
      plans: [{ id: "day-2", title: "Day 2", scope: "day", date: "2026-11-07", options: [{ id: "route-1", label: "Route 1" }, { id: "route-2", label: "Route 2" }] }],
    });
  }

  it("validates plans and the records that belong to them", () => {
    expect(tripIntegrityIssues(planned())).toEqual([]);
    const doc = planned();
    const broken: TripDocument = {
      ...doc,
      days: doc.days.map((day) => (day.id === "day-2-nara" ? { ...day, date: "2026-11-08" } : day)),
      notes: [{ id: "n", title: "N", text: "x", planOptionId: "route-9" }],
      plans: [
        { ...doc.plans[0], defaultOptionId: "route-7" },
        { id: "trip", title: "Trip", scope: "trip", date: null, options: [{ id: "route-1", label: "Again" }, { id: "b", label: "B" }] },
        { id: "no-date", title: "Day", scope: "day", date: null, options: [{ id: "c", label: "C" }, { id: "d", label: "D" }] },
      ],
    };
    const messages = tripIntegrityIssues(broken).map((issue) => `${issue.path.join(".")}: ${issue.message}`);
    expect(messages).toEqual(expect.arrayContaining([
      "plans.0.defaultOptionId: unknown id \"route-7\"",
      "plans.1.options.0.id: duplicate plan option id \"route-1\"",
      "plans.2.date: a day plan needs its date",
      "notes.0.planOptionId: unknown id \"route-9\"",
      "days.2.date: must be 2026-11-07, the date of plan \"day-2\"",
    ]));
    expect(tripDocumentSchema.safeParse({ ...doc, plans: [{ id: "p", title: "P", options: [{ id: "only", label: "Only" }] }] }).success).toBe(false);
  });

  it("shows only the picked options' records", () => {
    const doc = planned();
    expect(selectedPlanOptionId(doc.plans[0])).toBe("route-1");
    expect(selectedPlanOptionId({ ...doc.plans[0], defaultOptionId: "route-2" })).toBe("route-2");
    expect(selectedPlanOptionId(doc.plans[0], { "day-2": "gone" })).toBe("route-1");

    const first = activeTripDocument(doc);
    expect(first.days.map((day) => day.id)).toEqual(["day-1", "day-2-arashiyama"]);
    expect(first.transports.map((transport) => transport.id)).toEqual(["haruka"]);
    expect(first.hotels.map((hotel) => hotel.id)).toEqual(["ryokan"]);
    expect(first.expenses.map((expense) => expense.id)).toEqual(["haruka-fare"]);
    // Nara is only visited by route 2.
    expect(first.places.map((place) => place.id)).toEqual(["kyoto", "kix"]);
    expect(first.plans).toHaveLength(1);

    const second = activeTripDocument(doc, { "day-2": "route-2" });
    expect(second.days.map((day) => day.id)).toEqual(["day-1", "day-2-nara"]);
    expect(second.places.map((place) => place.id)).toContain("nara");
    expect(tripIntegrityIssues(second)).toEqual([]);
    expect(tripIntegrityIssues(first)).toEqual([]);
  });

  it("resolves and deletes plans with their records", () => {
    const doc = planned();
    const resolved = tripDocumentSchema.parse(applyOperations(doc, [{ op: "resolve_plan", id: "day-2", optionId: "route-2" }]));
    expect(resolved.plans).toEqual([]);
    expect(resolved.days.map((day) => [day.id, day.planOptionId ?? null])).toEqual([["day-1", null], ["day-2-nara", null]]);
    expect(resolved.hotels.map((hotel) => hotel.id)).toEqual(["ryokan", "nara-inn"]);

    const deleted = tripDocumentSchema.parse(applyOperations(doc, [{ op: "delete", collection: "plans", id: "day-2" }]));
    expect(deleted.plans).toEqual([]);
    expect(deleted.days.map((day) => day.id)).toEqual(["day-1"]);
    expect(deleted.transports.map((transport) => transport.id)).toEqual(["haruka"]);
    expect(deleted.hotels.map((hotel) => hotel.id)).toEqual(["ryokan"]);
    expect(deleted.expenses.map((expense) => expense.id)).toEqual(["haruka-fare"]);

    // Unknown ids change nothing.
    expect(applyOperations(doc, [{ op: "resolve_plan", id: "day-2", optionId: "nope" }])).toEqual(doc);
    const upserted = applyOperations(minimal(), [tripOperationSchema.parse({ op: "upsert_plan", plan: doc.plans[0] })]);
    expect(upserted.plans.map((plan) => plan.id)).toEqual(["day-2"]);
  });

  it("lists plans in the trip's text", () => {
    const text = tripText(planned());
    expect(text).toContain("Day 2 · 2026-11-07 · Nara deer [Day 2: Route 2]");
    expect(text).toContain("- Day 2 (2026-11-07): Route 1 / Route 2");
  });
});
