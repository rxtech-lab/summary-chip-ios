import { and, eq, inArray, isNotNull, isNull, ne, or } from "drizzle-orm";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { FlightLookupInput } from "@/lib/contracts/flights";
import type { TripDocument } from "@/lib/contracts/trip";
import type { Database } from "@/lib/db/client";
import {
  flightLiveActivities,
  flights,
  flightSubscriptions,
  pushDevices,
  summaries,
  type FlightRow,
  type FlightSubscriptionRow,
} from "@/lib/db/schema";
import { detectFlightEvents, flightAlertText, type FlightEvent } from "@/lib/flights/changes";
import {
  contentStateChanged,
  endPayload,
  flightActivityAttributes,
  flightContentState,
  startPayload,
  updatePayload,
  type FlightContentState,
} from "@/lib/flights/live-activity";
import { FlightProviderError, getFlightProvider, type FlightEndpoint, type FlightProvider, type FlightStatus, type ProviderFlight } from "@/lib/flights/provider";
import { bestTime, delayMinutes, inLiveActivityWindow, LANDED_GRACE_MS, landedTime, MINUTE, planNextCheck, type TrackedFlight, type TrackingPlan } from "@/lib/flights/schedule";
import { getFlightTracker, type FlightTracker } from "@/lib/flights/tracker";
import { ApiError } from "@/lib/http/errors";
import { apnsConfigured, sendPush } from "@/lib/notifications/apns";
import { deliver, isDeadToken } from "./notifications";
import { translationLanguageFor } from "./translations";
import { findTripForViewer } from "./trips";

/** Tracked flights of trips, refreshed by the `trackFlight` workflow. Spec: `docs/flights.md`. */

/** A stored lookup younger than this is answered from the database. */
const LOOKUP_FRESH_MS = 10 * MINUTE;

export interface FlightDeps {
  provider?: FlightProvider;
  tracker?: FlightTracker;
  now?: () => number;
}

/* ------------------------------------------------------------------------------------------------
 * Flight numbers and ids
 * ---------------------------------------------------------------------------------------------- */

/** "cx 0520" → `{ code: "CX520", display: "CX 520" }`; null when it isn't a flight number. */
export function parseFlightNumber(raw: string): { code: string; display: string } | null {
  const compact = raw.toUpperCase().replace(/[\s-]/g, "");
  const match = /^([A-Z0-9]{2}|[A-Z]{3})(\d{1,4})([A-Z]?)$/.exec(compact);
  if (!match || !/[A-Z]/.test(match[1])) return null;
  const digits = String(Number(match[2]));
  return { code: `${match[1]}${digits}${match[3]}`, display: `${match[1]} ${digits}${match[3]}` };
}

export function flightIdFor(code: string, date: string): string {
  return `${code}-${date}`;
}

/* ------------------------------------------------------------------------------------------------
 * JSON
 * ---------------------------------------------------------------------------------------------- */

export interface FlightJson {
  id: string;
  flightNumber: string;
  date: string;
  status: FlightStatus;
  airline: ProviderFlight["airline"];
  aircraft: string | null;
  departure: FlightEndpoint;
  arrival: FlightEndpoint;
  delayMinutes: number | null;
  arrivalDelayMinutes: number | null;
  updatedAt: string;
}

export function toFlightJson(row: FlightRow): FlightJson | null {
  if (row.state !== "found" || !row.data) return null;
  const data = row.data;
  return {
    id: row.id,
    flightNumber: data.flightNumber || row.flightNumber,
    date: row.date,
    status: data.status,
    airline: data.airline,
    aircraft: data.aircraft,
    departure: data.departure,
    arrival: data.arrival,
    delayMinutes: delayMinutes(data.departure),
    arrivalDelayMinutes: delayMinutes(data.arrival),
    updatedAt: (row.fetchedAt ?? row.updatedAt).toISOString(),
  };
}

export interface TripFlightJson {
  transportId: string;
  optionId: string;
  segmentIndex: number;
  flightId: string;
  flightNumber: string;
  date: string;
  state: FlightRow["state"];
  flight: FlightJson | null;
}

/* ------------------------------------------------------------------------------------------------
 * Provider access
 * ---------------------------------------------------------------------------------------------- */

async function fetchFromProvider(provider: FlightProvider, code: string, date: string): Promise<ProviderFlight | null> {
  const legs = await provider.lookup({ flightNumber: code, date });
  return legs[0] ?? null;
}

function trackedFlight(row: Pick<FlightRow, "state" | "date" | "data" | "departureAt" | "arrivalAt" | "landedAt">): TrackedFlight {
  return {
    state: row.state,
    date: row.date,
    status: row.data?.status ?? null,
    departureAt: row.departureAt?.getTime() ?? null,
    arrivalAt: row.arrivalAt?.getTime() ?? null,
    landedAt: row.landedAt?.getTime() ?? null,
  };
}

/** The columns a provider answer sets on a flights row. */
function foundColumns(data: ProviderFlight, previousLandedAt: Date | null, now: number) {
  const departureAt = bestTime(data.departure);
  const arrivalAt = bestTime(data.arrival);
  const landedAt = landedTime(data, previousLandedAt?.getTime() ?? null, now);
  return {
    state: "found" as const,
    data,
    departureAt: departureAt === null ? null : new Date(departureAt),
    arrivalAt: arrivalAt === null ? null : new Date(arrivalAt),
    landedAt: landedAt === null ? null : new Date(landedAt),
    fetchedAt: new Date(now),
    updatedAt: new Date(now),
  };
}

async function findFlight(db: Database, id: string): Promise<FlightRow | undefined> {
  const rows = await db.select().from(flights).where(eq(flights.id, id)).limit(1);
  return rows[0];
}

/** Inserts the row when it is new (state `pending`); never overwrites an existing one. */
async function ensureFlightRow(db: Database, id: string, display: string, date: string, provider: string): Promise<void> {
  await db.insert(flights).values({ id, flightNumber: display, date, provider }).onConflictDoNothing();
}

/* ------------------------------------------------------------------------------------------------
 * Lookup
 * ---------------------------------------------------------------------------------------------- */

function flightNotFound(display: string, date: string): ApiError {
  return new ApiError(404, "FLIGHT_NOT_FOUND", `No flight ${display} was found on ${date}.`, { flightNumber: display, date });
}

/**
 * `POST /api/v1/flights/lookup`: the flight from the database when it is tracked or was looked up
 * in the last 10 minutes, else from the provider (and stored for everyone).
 */
export async function lookupFlight(db: Database, input: FlightLookupInput, deps: FlightDeps = {}): Promise<FlightJson> {
  const parsed = parseFlightNumber(input.flightNumber);
  if (!parsed) throw new ApiError(400, "VALIDATION_ERROR", "flightNumber: must be a flight number such as CX 520", [{ path: ["flightNumber"], message: "must be a flight number" }]);
  const now = (deps.now ?? Date.now)();
  const id = flightIdFor(parsed.code, input.date);
  const stored = await findFlight(db, id);
  const fresh = stored?.fetchedAt && (stored.trackingState === "tracking" || now - stored.fetchedAt.getTime() < LOOKUP_FRESH_MS);
  if (stored && fresh && stored.state !== "pending") {
    const json = toFlightJson(stored);
    if (!json) throw flightNotFound(parsed.display, input.date);
    return json;
  }

  const provider = deps.provider ?? await getFlightProvider();
  let data: ProviderFlight | null;
  try {
    data = await fetchFromProvider(provider, parsed.code, input.date);
  } catch (error) {
    if (error instanceof FlightProviderError) {
      // Better a slightly old answer than none.
      const json = stored && toFlightJson(stored);
      if (json) return json;
      throw new ApiError(502, "FLIGHT_PROVIDER_FAILED", "Flight information is unavailable right now. Please try again later.");
    }
    throw error;
  }
  await ensureFlightRow(db, id, parsed.display, input.date, provider.id);
  if (!data) {
    // Keep a tracked flight's last answer; only remember "not found" for flights never found.
    if (stored?.state !== "found") {
      await db.update(flights).set({ state: "not_found", fetchedAt: new Date(now), updatedAt: new Date(now) }).where(eq(flights.id, id));
    }
    throw flightNotFound(parsed.display, input.date);
  }
  const columns = foundColumns(data, stored?.landedAt ?? null, now);
  await db.update(flights).set({ ...columns, flightNumber: data.flightNumber || parsed.display, provider: provider.id }).where(eq(flights.id, id));
  return toFlightJson((await findFlight(db, id))!)!;
}

/* ------------------------------------------------------------------------------------------------
 * Trip ↔ flight subscriptions
 * ---------------------------------------------------------------------------------------------- */

interface TrackedSegment {
  transportId: string;
  optionId: string;
  segmentIndex: number;
  code: string;
  display: string;
  date: string;
}

/**
 * The flight segments of a trip worth tracking: in a transport that isn't just an idea, in its
 * chosen option (`selectedOptionId`, or the only one), with a flight number.
 */
export function trackedSegments(document: TripDocument): TrackedSegment[] {
  const out: TrackedSegment[] = [];
  for (const transport of document.transports) {
    if (transport.status === "idea") continue;
    const option = transport.selectedOptionId
      ? transport.options.find((candidate) => candidate.id === transport.selectedOptionId)
      : transport.options.length === 1 ? transport.options[0] : undefined;
    if (!option) continue;
    option.segments.forEach((segment, segmentIndex) => {
      if (segment.mode !== "flight" || !segment.flight?.flightNumber) return;
      const parsed = parseFlightNumber(segment.flight.flightNumber);
      if (!parsed) return;
      const date = (segment.departure ?? option.departure)?.slice(0, 10) ?? transport.date;
      out.push({ transportId: transport.id, optionId: option.id, segmentIndex, code: parsed.code, display: parsed.display, date });
    });
  }
  return out;
}

/**
 * Called after every trip save: makes the trip's subscriptions match its flight segments and
 * makes sure each subscribed flight has a running `trackFlight` workflow.
 */
export async function syncTripFlights(db: Database, tripId: string, ownerId: string, document: TripDocument, deps: FlightDeps = {}): Promise<void> {
  const wanted = trackedSegments(document);
  const existing = await db.select().from(flightSubscriptions).where(eq(flightSubscriptions.tripId, tripId));
  const key = (row: { transportId: string; optionId: string; segmentIndex: number }) => `${row.transportId}\u0000${row.optionId}\u0000${row.segmentIndex}`;
  const wantedByKey = new Map(wanted.map((segment) => [key(segment), segment]));

  const stale = existing.filter((row) => {
    const segment = wantedByKey.get(key(row));
    return !segment || flightIdFor(segment.code, segment.date) !== row.flightId;
  });
  for (const row of stale) {
    await db.delete(flightSubscriptions).where(and(
      eq(flightSubscriptions.tripId, tripId),
      eq(flightSubscriptions.transportId, row.transportId),
      eq(flightSubscriptions.optionId, row.optionId),
      eq(flightSubscriptions.segmentIndex, row.segmentIndex),
    ));
  }
  if (wanted.length === 0) return;

  const providerId = process.env.FLIGHT_PROVIDER?.trim() || (process.env.AERODATABOX_API_KEY ? "aerodatabox" : "mock");
  const flightIds = new Set<string>();
  for (const segment of wanted) {
    const flightId = flightIdFor(segment.code, segment.date);
    flightIds.add(flightId);
    await ensureFlightRow(db, flightId, segment.display, segment.date, deps.provider?.id ?? providerId);
    await db.insert(flightSubscriptions).values({
      tripId,
      transportId: segment.transportId,
      optionId: segment.optionId,
      segmentIndex: segment.segmentIndex,
      flightId,
      ownerId,
    }).onConflictDoNothing();
  }
  for (const flightId of flightIds) await ensureTracking(db, flightId, deps);
}

/** `GET /api/v1/trips/:id/flights`: the trip's tracked flights as stored. */
export async function tripFlights(db: Database, tripId: string, viewerId: string): Promise<{ flights: TripFlightJson[] }> {
  const found = await findTripForViewer(db, tripId, viewerId);
  if (!found) throw new ApiError(404, "NOT_FOUND", "The trip does not exist");
  const rows = await db.select({ subscription: flightSubscriptions, flight: flights })
    .from(flightSubscriptions)
    .innerJoin(flights, eq(flights.id, flightSubscriptions.flightId))
    .where(eq(flightSubscriptions.tripId, tripId));
  const order = new Map(found.trip.document.transports.map((transport, index) => [transport.id, index]));
  return {
    flights: rows
      .sort((a, b) => (order.get(a.subscription.transportId) ?? 0) - (order.get(b.subscription.transportId) ?? 0) || a.subscription.segmentIndex - b.subscription.segmentIndex)
      .map(({ subscription, flight }) => ({
        transportId: subscription.transportId,
        optionId: subscription.optionId,
        segmentIndex: subscription.segmentIndex,
        flightId: flight.id,
        flightNumber: flight.flightNumber,
        date: flight.date,
        state: flight.state,
        flight: toFlightJson(flight),
      })),
  };
}

/* ------------------------------------------------------------------------------------------------
 * Workflow runs
 * ---------------------------------------------------------------------------------------------- */

/**
 * Starts a `trackFlight` run unless one is active. The `tracking_state` compare-and-swap keeps
 * concurrent saves from starting two; a run that died (failed, cancelled) is replaced.
 */
export async function ensureTracking(db: Database, flightId: string, deps: FlightDeps = {}): Promise<void> {
  const tracker = deps.tracker ?? getFlightTracker();
  const row = await findFlight(db, flightId);
  if (!row || row.trackingState === "finished") return;
  if (row.trackingState === "tracking") {
    // Claimed by another save that is still starting its run.
    if (!row.trackingRunId) return;
    if (await tracker.isActive(row.trackingRunId).catch(() => true)) return;
  }
  const claim = await db.update(flights)
    .set({ trackingState: "tracking", trackingRunId: null })
    .where(and(
      eq(flights.id, flightId),
      row.trackingRunId ? eq(flights.trackingRunId, row.trackingRunId) : isNull(flights.trackingRunId),
      eq(flights.trackingState, row.trackingState),
    ));
  if (claim.rowsAffected === 0) return;
  try {
    const runId = await tracker.start(flightId);
    await db.update(flights).set({ trackingRunId: runId }).where(and(eq(flights.id, flightId), isNull(flights.trackingRunId)));
  } catch (error) {
    await db.update(flights).set({ trackingState: "idle" }).where(and(eq(flights.id, flightId), isNull(flights.trackingRunId)));
    throw error;
  }
}

/** Daily safety net (cleanup cron): restarts tracking of subscribed flights whose run died. */
export async function resumeFlightTracking(db: Database, deps: FlightDeps = {}): Promise<{ restarted: number }> {
  const rows = await db.selectDistinct({ id: flights.id, trackingRunId: flights.trackingRunId })
    .from(flights)
    .innerJoin(flightSubscriptions, eq(flightSubscriptions.flightId, flights.id))
    .where(ne(flights.trackingState, "finished"));
  let restarted = 0;
  for (const row of rows) {
    const before = row.trackingRunId;
    await ensureTracking(db, row.id, deps).catch((error) => console.warn("[flights] could not restart tracking", row.id, error));
    const after = await findFlight(db, row.id);
    if (after?.trackingRunId && after.trackingRunId !== before) restarted += 1;
  }
  return { restarted };
}

/* ------------------------------------------------------------------------------------------------
 * Refresh (one step of the `trackFlight` workflow)
 * ---------------------------------------------------------------------------------------------- */

interface Subscriber {
  subscription: FlightSubscriptionRow;
  language: TranslationLanguage | null;
}

async function subscribersOf(db: Database, flightId: string): Promise<Subscriber[]> {
  const rows = await db.select({ subscription: flightSubscriptions, language: summaries.language })
    .from(flightSubscriptions)
    .innerJoin(summaries, eq(summaries.id, flightSubscriptions.tripId))
    .where(eq(flightSubscriptions.flightId, flightId));
  return rows.map((row) => ({ subscription: row.subscription, language: translationLanguageFor(row.language) }));
}

/** One subscriber per owner (their first trip on this flight): alerts and activities are per person. */
function byOwner(subscribers: Subscriber[]): Subscriber[] {
  const seen = new Map<string, Subscriber>();
  for (const subscriber of subscribers) if (!seen.has(subscriber.subscription.ownerId)) seen.set(subscriber.subscription.ownerId, subscriber);
  return [...seen.values()];
}

async function sendAlerts(db: Database, flightId: string, flight: ProviderFlight, events: FlightEvent[], subscribers: Subscriber[]): Promise<void> {
  for (const subscriber of byOwner(subscribers)) {
    for (const event of events.slice(0, 3)) {
      const text = flightAlertText(event, flight, subscriber.language);
      const tripId = subscriber.subscription.tripId;
      await deliver(db, subscriber.subscription.ownerId, {
        aps: { alert: text, sound: "default", "thread-id": flightId },
        summaryId: tripId,
        tripId,
        userId: subscriber.subscription.ownerId,
        flightId,
      }, { collapseId: `${flightId}:${event.kind}` });
    }
  }
}

/** Sends one Live Activity push to every running activity of the flight, dropping dead tokens. */
async function pushToActivities(db: Database, flightId: string, payload: Record<string, unknown>, priority: 5 | 10, ownerIds?: Set<string>): Promise<void> {
  const activities = await db.select().from(flightLiveActivities).where(eq(flightLiveActivities.flightId, flightId));
  for (const activity of activities) {
    if (ownerIds && !ownerIds.has(activity.ownerId)) continue;
    try {
      const result = await sendPush(activity, payload, { type: "liveactivity", priority, collapseId: flightId });
      if (isDeadToken(result)) {
        await db.delete(flightLiveActivities).where(and(eq(flightLiveActivities.flightId, flightId), eq(flightLiveActivities.installationId, activity.installationId), eq(flightLiveActivities.token, activity.token)));
      } else if (result.status !== 200) {
        console.warn("[flights] APNs rejected a Live Activity push", { status: result.status, reason: result.reason });
      }
    } catch {
      console.warn("[flights] Live Activity push failed");
    }
  }
}

/** Ends the flight's activities (those of `ownerIds`, or all) and forgets their tokens. */
async function endActivities(db: Database, flightId: string, state: FlightContentState | null, dismissAt: number, now: number, ownerIds?: Set<string>): Promise<void> {
  if (state && apnsConfigured()) await pushToActivities(db, flightId, endPayload(state, dismissAt, now), 10, ownerIds);
  const activities = await db.select().from(flightLiveActivities).where(eq(flightLiveActivities.flightId, flightId));
  for (const activity of activities) {
    if (ownerIds && !ownerIds.has(activity.ownerId)) continue;
    await db.delete(flightLiveActivities).where(and(eq(flightLiveActivities.flightId, flightId), eq(flightLiveActivities.installationId, activity.installationId)));
  }
}

/**
 * Push-to-starts the Live Activity on the devices of owners who don't have one yet. An owner whose
 * app already reported a running activity is only marked as started.
 */
async function startActivities(db: Database, flightId: string, flight: ProviderFlight, state: FlightContentState, subscribers: Subscriber[], now: number): Promise<void> {
  const running = new Set((await db.select({ ownerId: flightLiveActivities.ownerId }).from(flightLiveActivities).where(eq(flightLiveActivities.flightId, flightId))).map((row) => row.ownerId));
  for (const subscriber of byOwner(subscribers.filter((candidate) => candidate.subscription.liveActivityStartedAt === null))) {
    const ownerId = subscriber.subscription.ownerId;
    let started = running.has(ownerId);
    if (!started && apnsConfigured()) {
      const devices = await db.select().from(pushDevices).where(and(eq(pushDevices.ownerId, ownerId), isNotNull(pushDevices.liveActivityStartToken)));
      const departs = flight.departure.estimatedLocal ?? flight.departure.scheduledLocal;
      const alert = flightAlertText({ kind: "time_change", delayMinutes: state.delayMinutes, departsLocal: departs }, flight, subscriber.language);
      const payload = startPayload(flightActivityAttributes(flightId, subscriber.subscription.tripId, flight), state, alert, now);
      for (const device of devices) {
        try {
          const result = await sendPush({ token: device.liveActivityStartToken!, environment: device.environment }, payload, { type: "liveactivity", priority: 10 });
          if (result.status === 200) started = true;
          else if (isDeadToken(result)) await db.update(pushDevices).set({ liveActivityStartToken: null }).where(and(eq(pushDevices.installationId, device.installationId), eq(pushDevices.liveActivityStartToken, device.liveActivityStartToken!)));
        } catch {
          console.warn("[flights] Live Activity push-to-start failed");
        }
      }
    }
    // Without a device that could start it, try again on the next refresh.
    if (started) {
      await db.update(flightSubscriptions).set({ liveActivityStartedAt: new Date(now) })
        .where(and(eq(flightSubscriptions.flightId, flightId), eq(flightSubscriptions.ownerId, ownerId)));
    }
  }
}

/**
 * Fetches the flight, stores it, alerts subscribers about changes and drives the Live Activities.
 * Returns when to check next. Provider failures never throw: the stored copy stays and the check
 * is retried. A flight nobody follows any more stops (and can be restarted by a later save).
 */
export async function refreshTrackedFlight(db: Database, flightId: string, deps: FlightDeps = {}): Promise<TrackingPlan> {
  const now = (deps.now ?? Date.now)();
  const row = await findFlight(db, flightId);
  if (!row) return { done: true, nextAt: now };
  const subscribers = await subscribersOf(db, flightId);
  const previousState = row.data ? flightContentState(row.data, now) : null;

  // Activities of people no longer on this flight (trip deleted, segment changed) end now.
  const followers = new Set(subscribers.map((subscriber) => subscriber.subscription.ownerId));
  const orphaned = (await db.select({ ownerId: flightLiveActivities.ownerId }).from(flightLiveActivities).where(eq(flightLiveActivities.flightId, flightId)))
    .map((activity) => activity.ownerId).filter((ownerId) => !followers.has(ownerId));
  if (orphaned.length) await endActivities(db, flightId, previousState, now, now, new Set(orphaned));

  if (subscribers.length === 0) {
    await db.update(flights).set({ trackingState: "idle", trackingRunId: null, updatedAt: new Date(now) }).where(eq(flights.id, flightId));
    return { done: true, nextAt: now };
  }

  let updated: FlightRow = row;
  let events: FlightEvent[] = [];
  let retryAt: number | null = null;
  try {
    const provider = deps.provider ?? await getFlightProvider();
    const data = await fetchFromProvider(provider, flightId.slice(0, -(row.date.length + 1)), row.date);
    if (data) {
      const detected = row.state === "found" && row.data ? detectFlightEvents(row.data, data, row.alertState) : { events: [], alertState: { delayMinutes: delayMinutes(data.departure) ?? 0 } };
      events = detected.events;
      const columns = { ...foundColumns(data, row.landedAt, now), alertState: detected.alertState, flightNumber: data.flightNumber || row.flightNumber };
      await db.update(flights).set(columns).where(eq(flights.id, flightId));
      updated = { ...row, ...columns };
    } else if (row.state !== "found") {
      const columns = { state: "not_found" as const, fetchedAt: new Date(now), updatedAt: new Date(now) };
      await db.update(flights).set(columns).where(eq(flights.id, flightId));
      updated = { ...row, ...columns };
    }
    // A flight that disappears after it was found keeps its last answer.
  } catch (error) {
    if (!(error instanceof FlightProviderError)) throw error;
    console.warn("[flights] provider failed", flightId, error.message);
    retryAt = now + Math.max(error.retryAfterMs ?? 0, 10 * MINUTE);
  }

  const tracked = trackedFlight(updated);
  const data = updated.data;
  if (data && updated.state === "found") {
    if (events.length) await sendAlerts(db, flightId, data, events, subscribers);
    const state = flightContentState(data, now);
    if (inLiveActivityWindow(tracked, now) && apnsConfigured()) {
      await startActivities(db, flightId, data, state, subscribers, now);
      if (events.length || contentStateChanged(previousState, state)) {
        const alert = events.length ? flightAlertText(events[0], data, subscribers[0].language) : null;
        await pushToActivities(db, flightId, updatePayload(state, alert, now), events.length ? 10 : 5);
      }
    }
  }

  const plan = planNextCheck(tracked, now);
  if (plan.done) {
    const state = data ? flightContentState(data, now) : null;
    // A cancelled flight's activity stays on screen for half an hour so the news is seen.
    const dismissAt = tracked.landedAt !== null ? tracked.landedAt + LANDED_GRACE_MS : now + 30 * MINUTE;
    await endActivities(db, flightId, state, Math.max(dismissAt, now), now);
    await db.update(flights).set({ trackingState: "finished", trackingRunId: null, updatedAt: new Date(now) }).where(eq(flights.id, flightId));
    return plan;
  }
  return retryAt === null ? plan : { done: false, nextAt: Math.min(Math.max(plan.nextAt, retryAt), now + 6 * 60 * MINUTE) };
}

/* ------------------------------------------------------------------------------------------------
 * Live Activity tokens
 * ---------------------------------------------------------------------------------------------- */

/** `POST /api/v1/devices/live-activity`: the installation's push-to-start token. */
export async function setLiveActivityStartToken(db: Database, ownerId: string, installationId: string, token: string | null): Promise<void> {
  const result = await db.update(pushDevices).set({ liveActivityStartToken: token })
    .where(and(eq(pushDevices.installationId, installationId), eq(pushDevices.ownerId, ownerId)));
  if (result.rowsAffected === 0) throw new ApiError(404, "DEVICE_NOT_REGISTERED", "Register the device for notifications first");
}

/** `PUT /api/v1/flights/:flightId/live-activity`: a running activity's update token. */
export async function registerFlightLiveActivity(
  db: Database,
  ownerId: string,
  flightId: string,
  input: { installationId: string; token: string; environment: "sandbox" | "production" },
  deps: FlightDeps = {},
): Promise<void> {
  const subscribed = await db.select({ flightId: flightSubscriptions.flightId }).from(flightSubscriptions)
    .where(and(eq(flightSubscriptions.flightId, flightId), eq(flightSubscriptions.ownerId, ownerId))).limit(1);
  if (subscribed.length === 0) throw new ApiError(404, "NOT_FOUND", "The flight is not in any of your trips");
  const now = new Date((deps.now ?? Date.now)());
  const row = { flightId, installationId: input.installationId, ownerId, token: input.token, environment: input.environment, updatedAt: now };
  await db.insert(flightLiveActivities).values(row).onConflictDoUpdate({
    target: [flightLiveActivities.flightId, flightLiveActivities.installationId],
    set: row,
  });
  await db.update(flightSubscriptions).set({ liveActivityStartedAt: now })
    .where(and(eq(flightSubscriptions.flightId, flightId), eq(flightSubscriptions.ownerId, ownerId), isNull(flightSubscriptions.liveActivityStartedAt)));
}

export async function removeFlightLiveActivity(db: Database, ownerId: string, flightId: string, installationId: string): Promise<void> {
  await db.delete(flightLiveActivities).where(and(
    eq(flightLiveActivities.flightId, flightId),
    eq(flightLiveActivities.installationId, installationId),
    eq(flightLiveActivities.ownerId, ownerId),
  ));
}

/** Flights nobody follows whose day is long past: rows only the lookup cache still holds. */
export async function deleteStaleFlights(db: Database, now = new Date()): Promise<number> {
  const cutoff = new Date(now.getTime() - 7 * 24 * 60 * MINUTE).toISOString().slice(0, 10);
  const rows = await db.select({ id: flights.id, date: flights.date }).from(flights)
    .leftJoin(flightSubscriptions, eq(flightSubscriptions.flightId, flights.id))
    .where(and(isNull(flightSubscriptions.flightId), or(eq(flights.trackingState, "idle"), eq(flights.trackingState, "finished"))));
  const stale = rows.filter((row) => row.date < cutoff).map((row) => row.id);
  for (let offset = 0; offset < stale.length; offset += 100) {
    await db.delete(flights).where(inArray(flights.id, stale.slice(offset, offset + 100)));
  }
  return stale.length;
}
