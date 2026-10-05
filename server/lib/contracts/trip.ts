import { z } from "zod";
import { sourceSchema } from "@/lib/contracts/api";
import { viewSpecIssues, viewSpecSchema } from "@/lib/contracts/trip-view";

/**
 * The standard trip diary document (v1). One JSON document per trip, stored in `trips.document`.
 * Records reference each other by stable string ids (`placeId`, `stayId`, `transportIds`…), so
 * agents can upsert or delete one record without rewriting the rest. Swift mirror:
 * `Packages/SummaryKit/Sources/SummaryKit/Models/Trip.swift`. Spec: `docs/trips.md`.
 */

export const TRIP_DOCUMENT_VERSION = 1;

const id = z.string().trim().min(1).max(80);
const shortText = z.string().trim().max(300);
const longText = z.string().trim().max(4000);
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "must be YYYY-MM-DD");
/** Local wall-clock time at the place, `YYYY-MM-DDTHH:mm` (no offset; the trip's `timeZone` applies). */
const localDateTime = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, "must be YYYY-MM-DDTHH:mm");
const clockTime = z.string().regex(/^\d{2}:\d{2}$/, "must be HH:mm");
const currencyCode = z.string().trim().regex(/^[A-Z]{3}$/, "must be an ISO 4217 code");
const url = z.string().trim().url().max(4096);

export const coordinateSchema = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
});

export const moneySchema = z.object({ amount: z.number().min(0), currency: currencyCode });

export const PLACE_KINDS = ["city", "station", "airport", "hotel", "poi", "port"] as const;
export const ROUTE_KINDS = ["out", "side", "back", "ferry", "airport", "stay"] as const;
export const MOMENT_SLOTS = ["morning", "afternoon", "evening", "night"] as const;
export const BOOKING_STATUSES = ["idea", "planned", "booked"] as const;
export const SEGMENT_MODES = ["train", "flight", "ferry", "bus", "car", "walk", "other"] as const;
export const TRAIN_CATEGORIES = ["shinkansen", "limited_express", "rapid", "local", "other"] as const;
export const SEAT_CLASSES = ["reserved", "non_reserved", "green", "gran_class", "economy", "premium_economy", "business", "first"] as const;
export const EXPENSE_CATEGORIES = ["transport", "lodging", "food", "activity", "shopping", "pass", "other"] as const;

export const placeSchema = z.object({
  id,
  name: shortText.min(1),
  kind: z.enum(PLACE_KINDS).default("poi"),
  coordinate: coordinateSchema,
  address: shortText.nullish(),
  note: longText.nullish(),
  major: z.boolean().default(false),
});

export const dayRouteSchema = z.object({
  kind: z.enum(ROUTE_KINDS),
  placeIds: z.array(id).max(40).default([]),
  /** Optional drawn path; when absent clients connect the places in order. */
  path: z.array(coordinateSchema).max(2000).nullish(),
  summary: shortText.nullish(),
});

export const momentSchema = z.object({
  slot: z.enum(MOMENT_SLOTS),
  time: clockTime.nullish(),
  text: longText.min(1),
  placeId: id.nullish(),
});

export const daySchema = z.object({
  id,
  date: isoDate,
  title: shortText.min(1),
  short: shortText.nullish(),
  blurb: longText.nullish(),
  highlight: z.boolean().default(false),
  route: dayRouteSchema.nullish(),
  moments: z.array(momentSchema).max(24).default([]),
  tip: longText.nullish(),
  stayId: id.nullish(),
  transportIds: z.array(id).max(20).default([]),
});

export const trainDetailsSchema = z.object({
  operator: shortText.nullish(),
  line: shortText.nullish(),
  name: shortText.nullish(),
  number: shortText.nullish(),
  category: z.enum(TRAIN_CATEGORIES).default("other"),
  carNumber: shortText.nullish(),
  seat: shortText.nullish(),
  seatClass: z.enum(SEAT_CLASSES).nullish(),
});

export const flightDetailsSchema = z.object({
  airline: shortText.nullish(),
  flightNumber: shortText.min(1),
  fromIATA: z.string().trim().regex(/^[A-Z]{3}$/).nullish(),
  toIATA: z.string().trim().regex(/^[A-Z]{3}$/).nullish(),
  terminal: shortText.nullish(),
  gate: shortText.nullish(),
  seat: shortText.nullish(),
  seatClass: z.enum(SEAT_CLASSES).nullish(),
  bookingRef: shortText.nullish(),
});

export const segmentSchema = z.object({
  mode: z.enum(SEGMENT_MODES),
  fromPlaceId: id.nullish(),
  toPlaceId: id.nullish(),
  fromName: shortText.min(1),
  toName: shortText.min(1),
  departure: localDateTime.nullish(),
  arrival: localDateTime.nullish(),
  train: trainDetailsSchema.nullish(),
  flight: flightDetailsSchema.nullish(),
  price: moneySchema.nullish(),
  sourceUrl: url.nullish(),
});

export const transportOptionSchema = z.object({
  id,
  label: shortText.min(1),
  departure: localDateTime.nullish(),
  arrival: localDateTime.nullish(),
  duration: shortText.nullish(),
  fare: moneySchema.nullish(),
  warning: longText.nullish(),
  notes: z.array(longText).max(20).default([]),
  segments: z.array(segmentSchema).max(20).default([]),
});

export const transportSchema = z.object({
  id,
  date: isoDate,
  label: shortText.min(1),
  status: z.enum(BOOKING_STATUSES).default("planned"),
  selectedOptionId: id.nullish(),
  options: z.array(transportOptionSchema).min(1).max(10),
});

export const hotelSchema = z.object({
  id,
  name: shortText.min(1),
  placeId: id.nullish(),
  address: shortText.nullish(),
  checkIn: isoDate,
  checkOut: isoDate,
  checkInTime: clockTime.nullish(),
  confirmation: shortText.nullish(),
  price: moneySchema.nullish(),
  url: url.nullish(),
  status: z.enum(BOOKING_STATUSES).default("planned"),
});

export const expenseSchema = z.object({
  id,
  date: isoDate.nullish(),
  dayId: id.nullish(),
  category: z.enum(EXPENSE_CATEGORIES),
  title: shortText.min(1),
  amount: moneySchema,
  paid: z.boolean().default(false),
  /** The pass/bundle expense that covers this one (e.g. a JR pass). Covered rows don't add to the total. */
  coveredByExpenseId: id.nullish(),
  /** The transport or hotel this cost belongs to. */
  linkedId: id.nullish(),
});

export const noteSchema = z.object({ id, title: shortText.min(1), text: longText });
export const tripSourceSchema = z.object({ title: shortText.min(1), url });

/**
 * A custom view (a comparison table, a budget, a checklist…) drawn from a JSON spec of catalog
 * components (`trip-view.ts`). With `dayId` it shows inside that day; without, in the trip's Views section.
 */
export const tripViewSchema = z.object({
  id,
  title: shortText.min(1),
  dayId: id.nullish(),
  spec: viewSpecSchema,
});

const timeZone = z.string().trim().min(1).max(64);

const tripMetaFields = {
  title: shortText.min(1).max(200),
  subtitle: shortText.nullish(),
  intro: longText.nullish(),
  startDate: isoDate,
  endDate: isoDate,
  timeZone,
  currency: currencyCode,
};

const tripMetaShape = {
  ...tripMetaFields,
  timeZone: timeZone.default("UTC"),
  currency: currencyCode.default("USD"),
};

export const tripMetaSchema = z.object(tripMetaShape);
/**
 * A `set_meta` patch: only the fields given change (null clears `subtitle`/`intro`). No defaults —
 * zod 4 applies defaults inside `.partial()`, which would reset `timeZone`/`currency` on every patch.
 */
export const tripMetaPatchSchema = z.object(tripMetaFields).partial();

const tripDocumentBase = z.object({
  version: z.literal(TRIP_DOCUMENT_VERSION).default(TRIP_DOCUMENT_VERSION),
  ...tripMetaShape,
  places: z.array(placeSchema).max(500).default([]),
  days: z.array(daySchema).max(366).default([]),
  transports: z.array(transportSchema).max(500).default([]),
  hotels: z.array(hotelSchema).max(200).default([]),
  expenses: z.array(expenseSchema).max(2000).default([]),
  notes: z.array(noteSchema).max(100).default([]),
  sources: z.array(tripSourceSchema).max(200).default([]),
  views: z.array(tripViewSchema).max(50).default([]),
});

export type TripDocument = z.infer<typeof tripDocumentBase>;

/** The arrays of records with ids; the `collection` of a `delete` operation. */
export const TRIP_COLLECTIONS = ["places", "days", "transports", "hotels", "expenses", "notes", "views"] as const;

/** Problems with ids that point nowhere, duplicated ids, and dates outside the trip. */
export function tripIntegrityIssues(doc: TripDocument): { path: (string | number)[]; message: string }[] {
  const issues: { path: (string | number)[]; message: string }[] = [];
  if (doc.endDate < doc.startDate) issues.push({ path: ["endDate"], message: "must not be before startDate" });

  const collections = TRIP_COLLECTIONS;
  for (const key of collections) {
    const seen = new Set<string>();
    doc[key].forEach((item, index) => {
      if (seen.has(item.id)) issues.push({ path: [key, index, "id"], message: `duplicate id "${item.id}"` });
      seen.add(item.id);
    });
  }

  const places = new Set(doc.places.map((p) => p.id));
  const hotels = new Set(doc.hotels.map((h) => h.id));
  const transports = new Set(doc.transports.map((t) => t.id));
  const days = new Set(doc.days.map((d) => d.id));
  const expenses = new Set(doc.expenses.map((e) => e.id));
  const linkable = new Set([...hotels, ...transports]);
  const ref = (ok: boolean, path: (string | number)[], value: string) => {
    if (!ok) issues.push({ path, message: `unknown id "${value}"` });
  };

  doc.days.forEach((day, i) => {
    day.route?.placeIds.forEach((pid, j) => ref(places.has(pid), ["days", i, "route", "placeIds", j], pid));
    day.moments.forEach((m, j) => m.placeId && ref(places.has(m.placeId), ["days", i, "moments", j, "placeId"], m.placeId));
    if (day.stayId) ref(hotels.has(day.stayId), ["days", i, "stayId"], day.stayId);
    day.transportIds.forEach((tid, j) => ref(transports.has(tid), ["days", i, "transportIds", j], tid));
  });
  doc.transports.forEach((t, i) => {
    if (t.selectedOptionId) ref(t.options.some((o) => o.id === t.selectedOptionId), ["transports", i, "selectedOptionId"], t.selectedOptionId);
    t.options.forEach((o, j) => o.segments.forEach((s, k) => {
      if (s.fromPlaceId) ref(places.has(s.fromPlaceId), ["transports", i, "options", j, "segments", k, "fromPlaceId"], s.fromPlaceId);
      if (s.toPlaceId) ref(places.has(s.toPlaceId), ["transports", i, "options", j, "segments", k, "toPlaceId"], s.toPlaceId);
    }));
  });
  doc.hotels.forEach((h, i) => {
    if (h.placeId) ref(places.has(h.placeId), ["hotels", i, "placeId"], h.placeId);
    if (h.checkOut < h.checkIn) issues.push({ path: ["hotels", i, "checkOut"], message: "must not be before checkIn" });
  });
  doc.views.forEach((v, i) => {
    if (v.dayId) ref(days.has(v.dayId), ["views", i, "dayId"], v.dayId);
    for (const issue of viewSpecIssues(v.spec)) issues.push({ path: ["views", i, "spec", ...issue.path], message: issue.message });
  });
  doc.expenses.forEach((e, i) => {
    if (e.dayId) ref(days.has(e.dayId), ["expenses", i, "dayId"], e.dayId);
    if (e.coveredByExpenseId) ref(expenses.has(e.coveredByExpenseId) && e.coveredByExpenseId !== e.id, ["expenses", i, "coveredByExpenseId"], e.coveredByExpenseId);
    if (e.linkedId) ref(linkable.has(e.linkedId), ["expenses", i, "linkedId"], e.linkedId);
  });
  return issues;
}

export const tripDocumentSchema = tripDocumentBase.superRefine((doc, ctx) => {
  for (const issue of tripIntegrityIssues(doc)) ctx.addIssue({ code: "custom", path: issue.path, message: issue.message });
});

/** Entity-level edits used by the MCP tools, the trip agent and the app. Applied in order, atomically. */
export const tripOperationSchema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("set_meta"), meta: tripMetaPatchSchema }),
  z.object({ op: z.literal("upsert_place"), place: placeSchema }),
  z.object({ op: z.literal("upsert_day"), day: daySchema }),
  z.object({ op: z.literal("upsert_transport"), transport: transportSchema }),
  z.object({ op: z.literal("upsert_hotel"), hotel: hotelSchema }),
  z.object({ op: z.literal("upsert_expense"), expense: expenseSchema }),
  z.object({ op: z.literal("upsert_note"), note: noteSchema }),
  z.object({ op: z.literal("upsert_view"), view: tripViewSchema }),
  z.object({ op: z.literal("add_source"), source: tripSourceSchema }),
  z.object({
    op: z.literal("delete"),
    collection: z.enum(TRIP_COLLECTIONS),
    id,
  }),
]);
export type TripOperation = z.infer<typeof tripOperationSchema>;

export const createTripSchema = z.object({
  document: tripDocumentSchema,
  visibility: z.enum(["public", "private"]).default("private"),
});

export const putTripSchema = z.object({
  document: tripDocumentSchema,
  /** The revision the client edited. A mismatch returns 409 TRIP_REVISION_CONFLICT. */
  revision: z.number().int().min(0),
});

export const tripOperationsRequestSchema = z.object({
  operations: z.array(tripOperationSchema).min(1).max(200),
  revision: z.number().int().min(0).nullish(),
});

export const ingestTripSchema = z.object({
  source: sourceSchema,
  instructions: z.string().trim().max(2000).nullish(),
});
