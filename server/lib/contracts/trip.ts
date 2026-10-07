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
export const PLAN_SCOPES = ["trip", "day"] as const;
export const MAX_PLAN_OPTIONS = 6;

/**
 * The plan option a record belongs to (`plans[].options[].id`). Without it the record is shared by
 * every option; with it, it only counts while that option is the one picked.
 */
const planOptionId = id.nullish();

/** An image on the web (https only): clients and the PDF export load it straight from its URL. */
export const imageUrl = z.string().trim().max(4096).url().refine((value) => value.startsWith("https://"), "must be an https URL");

export const MAX_PLACE_PHOTOS = 12;

/** A photo of a place: a direct image URL plus what it shows and who took it. */
export const photoSchema = z.object({
  url: imageUrl,
  caption: shortText.nullish(),
  /** Attribution shown under the photo ("Photo: Wikimedia Commons / Jane Doe"). */
  credit: shortText.nullish(),
  /** The page the photo came from. */
  sourceUrl: url.nullish(),
});

/** One line of a place's price list: an admission tier, a set menu, a parking rate. No price means free. */
export const priceItemSchema = z.object({
  label: shortText.min(1),
  price: moneySchema.nullish(),
  note: shortText.nullish(),
});

/** A place's fields without defaults, so `update_place` patches change only what they name. */
const placeFields = {
  name: shortText.min(1),
  kind: z.enum(PLACE_KINDS),
  coordinate: coordinateSchema,
  address: shortText.nullish(),
  note: longText.nullish(),
  major: z.boolean(),
  /** What the place is and why it's worth the visit, like a guidebook entry. */
  description: longText.nullish(),
  photos: z.array(photoSchema).max(MAX_PLACE_PHOTOS),
  /** Opening hours as written ("9:00–17:00, closed Mondays"). */
  hours: shortText.nullish(),
  /** How long a visit takes ("1–2 h"). */
  visitDuration: shortText.nullish(),
  pricing: z.array(priceItemSchema).max(30),
  website: url.nullish(),
  phone: shortText.nullish(),
};

export const placeSchema = z.object({
  id,
  ...placeFields,
  kind: placeFields.kind.default("poi"),
  /** Drawn larger on the map. */
  major: placeFields.major.default(false),
  photos: placeFields.photos.default([]),
  pricing: placeFields.pricing.default([]),
});

/** An `update_place` patch: only the fields given change; `null` clears an optional one. */
export const placePatchSchema = z.object(placeFields).partial();

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
  planOptionId,
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
  planOptionId,
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
  planOptionId,
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
  planOptionId,
});

export const noteSchema = z.object({ id, title: shortText.min(1), text: longText, planOptionId });
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
  planOptionId,
});

export const planOptionSchema = z.object({
  /** Unique across all of the trip's plans: records point at it with `planOptionId`. */
  id,
  /** "Route 1 · Coast", "Rainy day", "Via Sendai". */
  label: shortText.min(1),
  /** What sets this option apart, shown under the picker. */
  summary: longText.nullish(),
});

/**
 * A choice between alternative plans ("Route 1 / Route 2 / Route 3"), for the whole trip
 * (`scope: "trip"`) or one day (`scope: "day"` with its `date`). Days, transports, hotels,
 * expenses, notes and views tagged with an option's id only show while that option is picked;
 * each reader's pick is saved per user, else `defaultOptionId`, else the first option.
 */
export const planSchema = z.object({
  id,
  title: shortText.min(1),
  scope: z.enum(PLAN_SCOPES).default("trip"),
  /** The day a `day` plan decides (`YYYY-MM-DD`). Its options' days must be on it. */
  date: isoDate.nullish(),
  options: z.array(planOptionSchema).min(2).max(MAX_PLAN_OPTIONS),
  defaultOptionId: id.nullish(),
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
  plans: z.array(planSchema).max(50).default([]),
});

export type TripDocument = z.infer<typeof tripDocumentBase>;

/** The arrays of records with ids; the `collection` of a `delete` operation. */
export const TRIP_COLLECTIONS = ["places", "days", "transports", "hotels", "expenses", "notes", "views", "plans"] as const;
/** The collections whose records can belong to a plan option (`planOptionId`). */
export const PLANNED_COLLECTIONS = ["days", "transports", "hotels", "expenses", "notes", "views"] as const;

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

  // Plans: option ids are unique across plans, and every planOptionId names one.
  const optionPlans = new Map<string, TripDocument["plans"][number]>();
  doc.plans.forEach((plan, i) => {
    if (plan.scope === "day") {
      if (!plan.date) issues.push({ path: ["plans", i, "date"], message: "a day plan needs its date" });
      else if (plan.date < doc.startDate || plan.date > doc.endDate) issues.push({ path: ["plans", i, "date"], message: "must be within the trip's dates" });
    }
    plan.options.forEach((option, j) => {
      if (optionPlans.has(option.id)) issues.push({ path: ["plans", i, "options", j, "id"], message: `duplicate plan option id "${option.id}"` });
      optionPlans.set(option.id, plan);
    });
    if (plan.defaultOptionId) ref(plan.options.some((o) => o.id === plan.defaultOptionId), ["plans", i, "defaultOptionId"], plan.defaultOptionId);
  });
  for (const key of PLANNED_COLLECTIONS) {
    (doc[key] as { planOptionId?: string | null }[]).forEach((record, i) => {
      if (!record.planOptionId) return;
      const plan = optionPlans.get(record.planOptionId);
      ref(plan !== undefined, [key, i, "planOptionId"], record.planOptionId);
      if (key === "days" && plan?.scope === "day" && plan.date && (record as { date: string }).date !== plan.date) {
        issues.push({ path: [key, i, "date"], message: `must be ${plan.date}, the date of plan "${plan.id}"` });
      }
    });
  }
  return issues;
}

export const tripDocumentSchema = tripDocumentBase.superRefine((doc, ctx) => {
  for (const issue of tripIntegrityIssues(doc)) ctx.addIssue({ code: "custom", path: issue.path, message: issue.message });
});

/** Entity-level edits used by the MCP tools, the trip agent and the app. Applied in order, atomically. */
export const tripOperationSchema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("set_meta"), meta: tripMetaPatchSchema }),
  z.object({ op: z.literal("upsert_place"), place: placeSchema }),
  /** Changes some of a place's fields and appends photos, without resending the record. Unknown ids are ignored. */
  z.object({
    op: z.literal("update_place"),
    id,
    changes: placePatchSchema.default({}),
    addPhotos: z.array(photoSchema).max(MAX_PLACE_PHOTOS).default([]),
  }),
  z.object({ op: z.literal("upsert_day"), day: daySchema }),
  z.object({ op: z.literal("upsert_transport"), transport: transportSchema }),
  z.object({ op: z.literal("upsert_hotel"), hotel: hotelSchema }),
  z.object({ op: z.literal("upsert_expense"), expense: expenseSchema }),
  z.object({ op: z.literal("upsert_note"), note: noteSchema }),
  z.object({ op: z.literal("upsert_view"), view: tripViewSchema }),
  z.object({ op: z.literal("upsert_plan"), plan: planSchema }),
  /**
   * Settles a plan on one option: that option's records stay (no longer tagged), the other
   * options' records and the plan are deleted. Unknown plan or option ids are ignored.
   */
  z.object({ op: z.literal("resolve_plan"), id, optionId: id }),
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

/** `PUT /api/v1/trips/:id/plan-selections`: the reader picks an option of a plan; `null` goes back to the default. */
export const planSelectionSchema = z.object({
  planId: id,
  optionId: id.nullable(),
});

export const ingestTripSchema = z.object({
  source: sourceSchema,
  instructions: z.string().trim().max(2000).nullish(),
});
