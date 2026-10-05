import { MAX_PLACE_PHOTOS, type TRIP_COLLECTIONS, type TripDocument, type TripOperation } from "@/lib/contracts/trip";
import { viewText } from "@/lib/contracts/trip-view";

/**
 * Pure helpers over a `TripDocument`: applying entity-level operations, and the text a trip is
 * listed, searched and embedded by. No database access, so unit tests and the trip agent use them.
 */

type Collection = (typeof TRIP_COLLECTIONS)[number];

function upsert<T extends { id: string }>(items: T[], item: T): T[] {
  const index = items.findIndex((existing) => existing.id === item.id);
  if (index === -1) return [...items, item];
  return items.map((existing, i) => (i === index ? item : existing));
}

/** Stable sort by a string key; records without one keep their place after the dated ones. */
function byKey<T>(items: T[], key: (item: T) => string): T[] {
  return items.map((item, index) => ({ item, index }))
    .sort((a, b) => key(a.item).localeCompare(key(b.item)) || a.index - b.index)
    .map(({ item }) => item);
}

/** Removes a record and every reference to it, so a delete never leaves a dangling id behind. */
function remove(doc: TripDocument, collection: Collection, id: string): TripDocument {
  const next: TripDocument = { ...doc, [collection]: (doc[collection] as { id: string }[]).filter((item) => item.id !== id) };
  switch (collection) {
    case "places":
      next.days = next.days.map((day) => ({
        ...day,
        route: day.route ? { ...day.route, placeIds: day.route.placeIds.filter((placeId) => placeId !== id) } : day.route,
        moments: day.moments.map((moment) => (moment.placeId === id ? { ...moment, placeId: null } : moment)),
      }));
      next.hotels = next.hotels.map((hotel) => (hotel.placeId === id ? { ...hotel, placeId: null } : hotel));
      next.transports = next.transports.map((transport) => ({
        ...transport,
        options: transport.options.map((option) => ({
          ...option,
          segments: option.segments.map((segment) => ({
            ...segment,
            fromPlaceId: segment.fromPlaceId === id ? null : segment.fromPlaceId,
            toPlaceId: segment.toPlaceId === id ? null : segment.toPlaceId,
          })),
        })),
      }));
      break;
    case "hotels":
      next.days = next.days.map((day) => (day.stayId === id ? { ...day, stayId: null } : day));
      next.expenses = next.expenses.map((expense) => (expense.linkedId === id ? { ...expense, linkedId: null } : expense));
      break;
    case "transports":
      next.days = next.days.map((day) => ({ ...day, transportIds: day.transportIds.filter((transportId) => transportId !== id) }));
      next.expenses = next.expenses.map((expense) => (expense.linkedId === id ? { ...expense, linkedId: null } : expense));
      break;
    case "days":
      next.expenses = next.expenses.map((expense) => (expense.dayId === id ? { ...expense, dayId: null } : expense));
      // The day's views move to the trip's Views section rather than disappearing.
      next.views = next.views.map((view) => (view.dayId === id ? { ...view, dayId: null } : view));
      break;
    case "expenses":
      next.expenses = next.expenses.map((expense) => (expense.coveredByExpenseId === id ? { ...expense, coveredByExpenseId: null } : expense));
      break;
    case "notes":
    case "views":
      break;
  }
  return next;
}

function applyOperation(doc: TripDocument, operation: TripOperation): TripDocument {
  switch (operation.op) {
    case "set_meta": {
      const meta = Object.fromEntries(Object.entries(operation.meta).filter(([, value]) => value !== undefined));
      return { ...doc, ...meta };
    }
    case "upsert_place":
      return { ...doc, places: upsert(doc.places, operation.place) };
    case "update_place":
      return {
        ...doc,
        places: doc.places.map((place) => {
          if (place.id !== operation.id) return place;
          const next = { ...place, ...operation.changes };
          // New photos go after the kept ones; a URL already there isn't added twice.
          const urls = new Set(next.photos.map((photo) => photo.url));
          const added = operation.addPhotos.filter((photo) => !urls.has(photo.url) && urls.add(photo.url));
          return { ...next, photos: [...next.photos, ...added].slice(0, MAX_PLACE_PHOTOS) };
        }),
      };
    case "upsert_day":
      return { ...doc, days: byKey(upsert(doc.days, operation.day), (day) => day.date) };
    case "upsert_transport":
      return { ...doc, transports: byKey(upsert(doc.transports, operation.transport), (transport) => transport.date) };
    case "upsert_hotel":
      return { ...doc, hotels: byKey(upsert(doc.hotels, operation.hotel), (hotel) => hotel.checkIn) };
    case "upsert_expense":
      return { ...doc, expenses: upsert(doc.expenses, operation.expense) };
    case "upsert_note":
      return { ...doc, notes: upsert(doc.notes, operation.note) };
    case "upsert_view":
      return { ...doc, views: upsert(doc.views, operation.view) };
    case "add_source":
      if (doc.sources.some((source) => source.url === operation.source.url)) return doc;
      return { ...doc, sources: [...doc.sources, operation.source] };
    case "delete":
      return remove(doc, operation.collection, operation.id);
  }
}

/**
 * Applies operations in order and returns the new document (the input is not modified). Upserts
 * replace the record with the same id or append it; days and transports stay sorted by date and
 * hotels by check-in. Deleting an unknown id is a no-op. The result is not validated: parse it
 * with `tripDocumentSchema` before saving.
 */
export function applyOperations(doc: TripDocument, operations: readonly TripOperation[]): TripDocument {
  return operations.reduce(applyOperation, structuredClone(doc));
}

function clip(value: string, max: number): string {
  const trimmed = value.replace(/\s+/g, " ").trim();
  return trimmed.length <= max ? trimmed : `${trimmed.slice(0, max - 1).trimEnd()}…`;
}

/** Days between two ISO dates, inclusive of both. */
export function tripDayCount(doc: Pick<TripDocument, "startDate" | "endDate">): number {
  const ms = Date.parse(`${doc.endDate}T00:00:00Z`) - Date.parse(`${doc.startDate}T00:00:00Z`);
  return Number.isFinite(ms) ? Math.max(1, Math.round(ms / 86_400_000) + 1) : 1;
}

/** The card fields a trip's summary row carries: its title, a one-paragraph summary, day titles as highlights and place names as keywords. */
export function tripDigest(doc: TripDocument): { title: string; summary: string; highlights: string[]; keywords: string[] } {
  const places = doc.places.filter((place) => place.major).map((place) => place.name);
  const stops = (places.length ? places : doc.places.map((place) => place.name)).slice(0, 8);
  const generated = [
    `${tripDayCount(doc)}-day trip, ${doc.startDate} – ${doc.endDate}`,
    stops.length ? `: ${stops.join(" → ")}` : "",
    ".",
  ].join("");
  return {
    title: clip(doc.title, 200),
    summary: clip(doc.intro || doc.subtitle || generated, 1200),
    highlights: doc.days.slice(0, 5).map((day) => clip(day.title, 300)),
    keywords: [...new Set(stops)].slice(0, 10).map((name) => name.slice(0, 60)),
  };
}

/**
 * The trip as plain text: what search and embeddings read (`summaries.content_text`), and what the
 * library chat sees as the trip's source.
 */
export function tripText(doc: TripDocument): string {
  const places = new Map(doc.places.map((place) => [place.id, place.name]));
  const hotels = new Map(doc.hotels.map((hotel) => [hotel.id, hotel.name]));
  const transports = new Map(doc.transports.map((transport) => [transport.id, transport]));
  const lines: (string | null | undefined)[] = [
    doc.title,
    doc.subtitle,
    `${doc.startDate} – ${doc.endDate} (${doc.timeZone})`,
    doc.intro,
  ];
  doc.days.forEach((day, index) => {
    lines.push("", `Day ${index + 1} · ${day.date} · ${day.title}${day.short ? ` (${day.short})` : ""}`, day.blurb);
    if (day.route?.placeIds.length) lines.push(`Route: ${day.route.placeIds.map((id) => places.get(id) ?? id).join(" → ")}`);
    if (day.route?.summary) lines.push(day.route.summary);
    for (const moment of day.moments) lines.push(`- ${moment.slot}${moment.time ? ` ${moment.time}` : ""}: ${moment.text}`);
    if (day.stayId) lines.push(`Stay: ${hotels.get(day.stayId) ?? day.stayId}`);
    for (const id of day.transportIds) {
      const transport = transports.get(id);
      if (transport) lines.push(`Transport: ${transport.label}`);
    }
    if (day.tip) lines.push(`Tip: ${day.tip}`);
  });
  if (doc.transports.length) {
    lines.push("", "Transport");
    for (const transport of doc.transports) {
      lines.push(`${transport.date} · ${transport.label} (${transport.status})`);
      for (const option of transport.options) {
        const times = option.departure || option.arrival ? ` ${option.departure?.slice(11) ?? "?"} → ${option.arrival?.slice(11) ?? "?"}` : "";
        lines.push(`- ${option.label}${times}`);
        for (const segment of option.segments) {
          const vehicle = segment.flight?.flightNumber ?? [segment.train?.name, segment.train?.number].filter(Boolean).join(" ");
          lines.push(`  ${segment.mode}: ${segment.fromName} → ${segment.toName}${vehicle ? ` · ${vehicle}` : ""}`);
        }
      }
    }
  }
  if (doc.hotels.length) {
    lines.push("", "Hotels");
    for (const hotel of doc.hotels) lines.push(`- ${hotel.name}, ${hotel.checkIn} – ${hotel.checkOut} (${hotel.status})${hotel.address ? `, ${hotel.address}` : ""}`);
  }
  const described = doc.places.filter((place) => place.description || place.hours || place.pricing.length);
  if (described.length) {
    lines.push("", "Places");
    for (const place of described) {
      lines.push(`- ${place.name}${place.address ? `, ${place.address}` : ""}`, place.description);
      if (place.hours) lines.push(`  Hours: ${place.hours}`);
      for (const item of place.pricing) lines.push(`  ${item.label}: ${item.price ? `${item.price.amount} ${item.price.currency}` : "free"}${item.note ? ` (${item.note})` : ""}`);
    }
  }
  for (const note of doc.notes) lines.push("", note.title, note.text);
  for (const view of doc.views) lines.push("", view.title, ...viewText(view.spec));
  return lines.filter((line): line is string => line !== null && line !== undefined).join("\n").replace(/\n{3,}/g, "\n\n").trim();
}
