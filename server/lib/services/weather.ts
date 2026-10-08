import { and, desc, eq, isNotNull, isNull, ne } from "drizzle-orm";
import type { TripDocument } from "@/lib/contracts/trip";
import type { Database } from "@/lib/db/client";
import { pushDevices, tripWeather, type StoredForecast, type TripWeatherData, type TripWeatherRow, type WeatherAlertState } from "@/lib/db/schema";
import { runAfter } from "@/lib/http/after";
import { ApiError } from "@/lib/http/errors";
import {
  assessNowcast,
  dailyCondition,
  detectNowcastEvent,
  nowcastAlertText,
  type Condition,
  type DayAheadLine,
} from "@/lib/weather/conditions";
import { getWeatherProvider, WeatherProviderError, type DailyForecast, type WeatherProvider } from "@/lib/weather/provider";
import {
  addDays,
  FORECAST_DAYS,
  FULL_REFRESH_MS,
  inForecastRange,
  isTimeZone,
  localParts,
  MINUTE,
  nowcastDate,
  planNextCheck,
  zonedTime,
  type DayZones,
  type WeatherPlan,
  type WeatherSchedule,
} from "@/lib/weather/schedule";
import { getWeatherTracker, type WeatherTracker } from "@/lib/weather/tracker";
import { deliver } from "./notifications";
import { activeTripDocument } from "./trip-document";
import { findPlanSelections, findTripForViewer } from "./trips";
import { translationLanguageFor } from "./translations";

/** Trip forecasts and weather alerts, refreshed by the `trackTripWeather` workflow. Spec: `docs/weather.md`. */

export interface WeatherDeps {
  provider?: WeatherProvider;
  tracker?: WeatherTracker;
  now?: () => number;
}

/** Places within this distance share a forecast. */
const SAME_WEATHER_KM = 15;
/** Locations per day: the first few distinct places it visits. */
const MAX_DAY_LOCATIONS = 3;
/** A nowcast older than this is not used for alerts or `now`. */
const NOWCAST_FRESH_MS = 30 * MINUTE;

/* ------------------------------------------------------------------------------------------------
 * Where each day is
 * ---------------------------------------------------------------------------------------------- */

export interface WeatherLocation {
  placeId: string | null;
  name: string;
  /** Rounded coordinate, the forecast's key. */
  key: string;
  lat: number;
  lng: number;
}

export interface DayLocations {
  dayId: string | null;
  date: string;
  locations: WeatherLocation[];
}

export function pointKey(point: { lat: number; lng: number }): string {
  return `${point.lat.toFixed(2)},${point.lng.toFixed(2)}`;
}

function distanceKm(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 12_742 * Math.asin(Math.min(1, Math.sqrt(h)));
}

function locationOf(place: TripDocument["places"][number]): WeatherLocation {
  const { lat, lng } = place.coordinate;
  return { placeId: place.id, name: place.name, key: pointKey({ lat, lng }), lat, lng };
}

/** Where the trip is when no day says: its first major place, else its first place. */
function tripFallback(document: TripDocument): WeatherLocation[] {
  const place = document.places.find((candidate) => candidate.major) ?? document.places[0];
  return place ? [locationOf(place)] : [];
}

/**
 * The places a day's weather is about: its route, then the places of its moments, then its hotel;
 * nearby places count once. A day naming none takes the previous day's last place (where the
 * traveller slept), else the trip's main place.
 */
export function tripLocations(document: TripDocument): DayLocations[] {
  const places = new Map(document.places.map((place) => [place.id, place]));
  const hotels = new Map(document.hotels.map((hotel) => [hotel.id, hotel]));
  const fallback = tripFallback(document);
  if (!document.days.length) {
    const out: DayLocations[] = [];
    for (let date = document.startDate; date <= document.endDate && out.length < 60; date = addDays(date, 1)) {
      out.push({ dayId: null, date, locations: fallback });
    }
    return out;
  }
  const days = [...document.days].sort((a, b) => a.date.localeCompare(b.date));
  let previous: WeatherLocation[] = [];
  return days.map((day) => {
    const ids = [
      ...day.route?.placeIds ?? [],
      ...day.moments.flatMap((moment) => moment.placeId ? [moment.placeId] : []),
      ...(day.stayId && hotels.get(day.stayId)?.placeId ? [hotels.get(day.stayId)!.placeId!] : []),
    ];
    const locations: WeatherLocation[] = [];
    for (const id of ids) {
      const place = places.get(id);
      if (!place || locations.length >= MAX_DAY_LOCATIONS) continue;
      if (locations.some((location) => distanceKm(location, place.coordinate) < SAME_WEATHER_KM)) continue;
      locations.push(locationOf(place));
    }
    const resolved = locations.length ? locations : previous.length ? previous.slice(-1) : fallback;
    if (resolved.length) previous = resolved;
    return { dayId: day.id, date: day.date, locations: resolved };
  });
}

/**
 * Where the traveller is in the next half hour: the place of the day's latest moment that starts
 * by then, else the day's first place. A moment's time is the wall clock at its place (`zoneOf`).
 */
export function nowcastLocation(
  document: TripDocument,
  entries: DayLocations[],
  date: string,
  now: number,
  zoneOf: (location: WeatherLocation) => string,
): WeatherLocation | null {
  const today = entries.filter((entry) => entry.date === date && entry.locations.length);
  if (!today.length) return null;
  const places = new Map(document.places.map((place) => [place.id, place]));
  const byId = new Map(document.days.map((day) => [day.id, day]));
  let best: { at: number; location: WeatherLocation } | null = null;
  for (const entry of today) {
    for (const moment of entry.dayId ? byId.get(entry.dayId)?.moments ?? [] : []) {
      const place = moment.placeId ? places.get(moment.placeId) : undefined;
      if (!moment.time || !place) continue;
      const location = locationOf(place);
      const at = zonedTime(date, Number(moment.time.slice(0, 2)) * 60 + Number(moment.time.slice(3, 5)), zoneOf(location));
      if (at <= now + 30 * MINUTE && (!best || at >= best.at)) best = { at, location };
    }
  }
  return best?.location ?? today[0].locations[0];
}

/** A place's IANA zone, from its stored forecast; the trip's zone until it has been fetched. */
function zoneFinder(data: TripWeatherData | null, fallback: string): (location: WeatherLocation) => string {
  return (location) => {
    const zone = data?.locations[location.key]?.timeZone;
    return zone && isTimeZone(zone) ? zone : fallback;
  };
}

/** Per trip date, the zones of the day's first place (morning) and last place (night). */
export function tripZones(entries: DayLocations[], zoneOf: (location: WeatherLocation) => string): Record<string, DayZones> {
  const zones: Record<string, DayZones> = {};
  for (const entry of entries) {
    const first = entry.locations[0];
    const last = entry.locations[entry.locations.length - 1];
    if (!first) continue;
    // Alternatives on one date: the first one's morning, the last one's night.
    zones[entry.date] = { morning: zones[entry.date]?.morning ?? zoneOf(first), evening: zoneOf(last) };
  }
  return zones;
}

function scheduleOf(document: TripDocument, entries: DayLocations[] = [], data: TripWeatherData | null = null, homeZone: string | null = null): WeatherSchedule {
  const timeZone = document.timeZone && isTimeZone(document.timeZone) ? document.timeZone : "UTC";
  return { startDate: document.startDate, endDate: document.endDate, timeZone, zones: tripZones(entries, zoneFinder(data, timeZone)), homeZone };
}

/** Where the owner is before the trip: the zone their most recently active device reported. */
async function homeZoneOf(db: Database, ownerId: string): Promise<string | null> {
  const [device] = await db.select({ timeZone: pushDevices.timeZone }).from(pushDevices)
    .where(and(eq(pushDevices.ownerId, ownerId), isNotNull(pushDevices.timeZone)))
    .orderBy(desc(pushDevices.updatedAt)).limit(1);
  return device?.timeZone && isTimeZone(device.timeZone) ? device.timeZone : null;
}

/** Forecast keys worth fetching: places of the days still ahead and within the forecast range. */
function wantedLocations(document: TripDocument, entries: DayLocations[], now: number): Map<string, WeatherLocation> {
  const today = localParts(now, scheduleOf(document).timeZone).date;
  const last = addDays(today, FORECAST_DAYS - 1);
  const wanted = new Map<string, WeatherLocation>();
  for (const entry of entries) {
    if (entry.date < today || entry.date > last) continue;
    for (const location of entry.locations) wanted.set(location.key, location);
  }
  return wanted;
}

/* ------------------------------------------------------------------------------------------------
 * JSON
 * ---------------------------------------------------------------------------------------------- */

export interface DailyForecastJson extends Omit<DailyForecast, "code"> {
  condition: Condition;
  weatherCode: number;
}

export interface TripWeatherJson {
  /** When a forecast was last fetched; null before the first one. */
  updatedAt: string | null;
  days: {
    dayId: string | null;
    date: string;
    locations: { placeId: string | null; name: string; forecast: DailyForecastJson | null }[];
  }[];
  /** During the trip's daytime: the weather where the reader is and in the next 30 minutes. */
  now: {
    dayId: string | null;
    placeId: string | null;
    name: string;
    condition: Condition;
    temperature: number | null;
    next30Minutes: { condition: Condition; at: string };
  } | null;
}

function dailyJson(forecast: DailyForecast): DailyForecastJson {
  const { code, ...rest } = forecast;
  return { ...rest, condition: dailyCondition(forecast), weatherCode: code };
}

function forecastFor(data: TripWeatherData | null, key: string, date: string): DailyForecast | null {
  return data?.locations[key]?.daily.find((day) => day.date === date) ?? null;
}

/** `GET /api/v1/trips/:id/weather`: the stored forecasts for every day (of every plan option), never fetched live. */
export async function tripWeatherForViewer(db: Database, tripId: string, viewerId: string, now = Date.now()): Promise<TripWeatherJson> {
  const found = await findTripForViewer(db, tripId, viewerId);
  if (!found) throw new ApiError(404, "NOT_FOUND", "The trip does not exist");
  const document = found.trip.document;
  const [row] = await db.select().from(tripWeather).where(eq(tripWeather.tripId, tripId)).limit(1);
  // A trip saved before weather tracking existed (or whose run died) starts on its first read.
  if (!row || row.trackingState === "idle") runAfter(() => syncTripWeather(db, tripId, document));
  const data = row?.data ?? null;
  const days = tripLocations(document).map((entry) => ({
    dayId: entry.dayId,
    date: entry.date,
    locations: entry.locations.map((location) => {
      const forecast = forecastFor(data, location.key, entry.date);
      return { placeId: location.placeId, name: location.name, forecast: forecast ? dailyJson(forecast) : null };
    }),
  }));

  let current: TripWeatherJson["now"] = null;
  if (data) {
    const active = activeTripDocument(document, await findPlanSelections(db, found.trip, viewerId));
    const entries = tripLocations(active);
    const schedule = scheduleOf(document, entries, data);
    const date = nowcastDate(schedule, now);
    const where = date ? nowcastLocation(active, entries, date, now, zoneFinder(data, schedule.timeZone)) : null;
    const stored = where ? data.locations[where.key] : undefined;
    const nowcast = stored && now - stored.fetchedAt < NOWCAST_FRESH_MS ? assessNowcast(stored.nowcast, stored.current, now) : null;
    if (where && nowcast) {
      current = {
        dayId: entries.find((entry) => entry.date === date && entry.locations.some((location) => location.key === where.key))?.dayId ?? null,
        placeId: where.placeId,
        name: where.name,
        condition: nowcast.current.condition,
        temperature: nowcast.current.temperature,
        next30Minutes: { condition: nowcast.upcoming.condition, at: new Date(nowcast.upcoming.at).toISOString() },
      };
    }
  }
  return { updatedAt: row?.fetchedAt?.toISOString() ?? null, days, now: current };
}

/* ------------------------------------------------------------------------------------------------
 * Workflow runs
 * ---------------------------------------------------------------------------------------------- */

async function findRow(db: Database, tripId: string): Promise<TripWeatherRow | undefined> {
  const rows = await db.select().from(tripWeather).where(eq(tripWeather.tripId, tripId)).limit(1);
  return rows[0];
}

/**
 * Starts a `trackTripWeather` run unless one is active. The `tracking_state` compare-and-swap keeps
 * concurrent saves from starting two; a run that died is replaced.
 */
async function ensureTracking(db: Database, tripId: string, deps: WeatherDeps): Promise<boolean> {
  const tracker = deps.tracker ?? getWeatherTracker();
  const row = await findRow(db, tripId);
  if (!row || row.trackingState === "finished") return false;
  if (row.trackingState === "tracking") {
    if (!row.trackingRunId) return false;
    if (await tracker.isActive(row.trackingRunId).catch(() => true)) return false;
  }
  const claim = await db.update(tripWeather)
    .set({ trackingState: "tracking", trackingRunId: null })
    .where(and(
      eq(tripWeather.tripId, tripId),
      row.trackingRunId ? eq(tripWeather.trackingRunId, row.trackingRunId) : isNull(tripWeather.trackingRunId),
      eq(tripWeather.trackingState, row.trackingState),
    ));
  if (claim.rowsAffected === 0) return false;
  try {
    const runId = await tracker.start(tripId);
    await db.update(tripWeather).set({ trackingRunId: runId }).where(and(eq(tripWeather.tripId, tripId), isNull(tripWeather.trackingRunId)));
    return true;
  } catch (error) {
    await db.update(tripWeather).set({ trackingState: "idle" }).where(and(eq(tripWeather.tripId, tripId), isNull(tripWeather.trackingRunId)));
    throw error;
  }
}

/**
 * Called after every trip save: makes sure a trip that isn't over has a running weather tracker
 * (a trip moved to later dates starts again), and fetches places the forecast doesn't cover yet
 * so the apps show them without waiting for the next check.
 */
export async function syncTripWeather(db: Database, tripId: string, document: TripDocument, deps: WeatherDeps = {}): Promise<void> {
  const now = (deps.now ?? Date.now)();
  const schedule = scheduleOf(document, tripLocations(document), (await findRow(db, tripId))?.data ?? null);
  if (planNextCheck(schedule, now).done) return;
  await db.insert(tripWeather).values({ tripId }).onConflictDoNothing();
  await db.update(tripWeather).set({ trackingState: "idle", trackingRunId: null, updatedAt: new Date(now) })
    .where(and(eq(tripWeather.tripId, tripId), eq(tripWeather.trackingState, "finished")));
  await ensureTracking(db, tripId, deps);
  // Places the stored forecast doesn't cover yet are fetched now, so the apps show them at once
  // instead of after the run's next check.
  if (!inForecastRange(schedule, now)) return;
  const row = await findRow(db, tripId);
  const missing = [...wantedLocations(document, tripLocations(document), now).values()].filter((location) => !row?.data?.locations[location.key]);
  if (!missing.length) return;
  try {
    const fetched = await fetchForecasts(deps, missing, now);
    const latest = await findRow(db, tripId);
    const data: TripWeatherData = { locations: { ...latest?.data?.locations, ...fetched.locations }, fullFetchedAt: latest?.data?.fullFetchedAt ?? null };
    await db.update(tripWeather).set({ data, provider: fetched.provider, fetchedAt: new Date(now), updatedAt: new Date(now) }).where(eq(tripWeather.tripId, tripId));
  } catch (error) {
    if (!(error instanceof WeatherProviderError)) throw error;
    console.warn("[weather] provider failed", error.message);
  }
}

/** Daily safety net (cleanup cron): restarts weather tracking of trips whose run died. */
export async function resumeWeatherTracking(db: Database, deps: WeatherDeps = {}): Promise<{ restarted: number }> {
  const rows = await db.select({ tripId: tripWeather.tripId }).from(tripWeather).where(ne(tripWeather.trackingState, "finished"));
  let restarted = 0;
  for (const row of rows) {
    const started = await ensureTracking(db, row.tripId, deps).catch((error) => {
      console.warn("[weather] could not restart tracking", row.tripId, error);
      return false;
    });
    if (started) restarted += 1;
  }
  return { restarted };
}

/* ------------------------------------------------------------------------------------------------
 * Refresh (one step of the `trackTripWeather` workflow)
 * ---------------------------------------------------------------------------------------------- */

async function fetchForecasts(deps: WeatherDeps, locations: WeatherLocation[], now: number): Promise<{ provider: string; locations: Record<string, StoredForecast> }> {
  const provider = deps.provider ?? await getWeatherProvider();
  const answers = await provider.forecast(locations.map(({ lat, lng }) => ({ lat, lng })));
  return {
    provider: provider.id,
    locations: Object.fromEntries(locations.map((location, index) => [location.key, { ...answers[index], lat: location.lat, lng: location.lng, fetchedAt: now }])),
  };
}

function payload(ownerId: string, tripId: string, alert: { title: string; body: string }) {
  return { aps: { alert, sound: "default", "thread-id": `weather:${tripId}` }, summaryId: tripId, tripId, userId: ownerId, kind: "weather" };
}

/** Fresh stored forecasts for tomorrow's active route, consumed by the combined trip briefing. */
export async function tripBriefingWeather(db: Database, tripId: string, document: TripDocument, date: string, now = Date.now()): Promise<DayAheadLine[]> {
  const [row] = await db.select({ data: tripWeather.data }).from(tripWeather).where(eq(tripWeather.tripId, tripId));
  const data = row?.data;
  if (!data) return [];
  const locations = tripLocations(document).filter((entry) => entry.date === date).flatMap((entry) => entry.locations);
  const seen = new Set<string>();
  const lines: DayAheadLine[] = [];
  for (const location of locations) {
    if (seen.has(location.key) || lines.length >= 3) continue;
    seen.add(location.key);
    const stored = data.locations[location.key];
    const forecast = forecastFor(data, location.key, date);
    if (!forecast || !stored || now - stored.fetchedAt > 2 * FULL_REFRESH_MS) continue;
    lines.push({ place: location.name, forecast });
  }
  return lines;
}

/**
 * Fetches the trip's forecasts (every place every 3 hours; in between only where the traveller is
 * now), stores them for the combined evening briefing and alerts when
 * the next 30 minutes turn bad or change. Returns when to check next. Provider failures never
 * throw: the stored forecast stays and the check is retried.
 */
export async function refreshTripWeather(db: Database, tripId: string, deps: WeatherDeps = {}): Promise<WeatherPlan> {
  const now = (deps.now ?? Date.now)();
  const row = await findRow(db, tripId);
  if (!row) return { done: true, nextAt: now };
  const found = await findTripForViewer(db, tripId, null, true);
  if (!found) {
    await db.delete(tripWeather).where(eq(tripWeather.tripId, tripId));
    return { done: true, nextAt: now };
  }
  const { summary, trip } = found;
  const document = trip.document;
  // Alerts follow the owner's own plan picks; the stored forecast covers every option. Times are
  // where the owner is: each place's own zone, and their device's zone before the trip.
  const active = activeTripDocument(document, await findPlanSelections(db, trip, summary.ownerId));
  const activeEntries = tripLocations(active);
  const homeZone = await homeZoneOf(db, summary.ownerId);
  let data: TripWeatherData = row.data ?? { locations: {}, fullFetchedAt: null };
  let schedule = scheduleOf(active, activeEntries, data, homeZone);
  let plan = planNextCheck(schedule, now);
  if (plan.done) {
    await db.update(tripWeather).set({ trackingState: "finished", trackingRunId: null, updatedAt: new Date(now) }).where(eq(tripWeather.tripId, tripId));
    return plan;
  }
  if (!inForecastRange(schedule, now)) return plan;

  const wanted = wantedLocations(document, tripLocations(document), now);
  const today = nowcastDate(schedule, now);
  const here = today ? nowcastLocation(active, activeEntries, today, now, zoneFinder(data, schedule.timeZone)) : null;
  if (here) wanted.set(here.key, here);

  const full = !data.fullFetchedAt || now - data.fullFetchedAt >= FULL_REFRESH_MS || [...wanted.keys()].some((key) => !data.locations[key]);
  const fetch = full ? [...wanted.values()] : here ? [here] : [];
  let retryAt: number | null = null;
  if (fetch.length) {
    try {
      const fetched = await fetchForecasts(deps, fetch, now);
      const kept = full ? Object.fromEntries(Object.entries(data.locations).filter(([key]) => wanted.has(key))) : data.locations;
      data = { locations: { ...kept, ...fetched.locations }, fullFetchedAt: full ? now : data.fullFetchedAt };
      await db.update(tripWeather).set({ data, provider: fetched.provider, fetchedAt: new Date(now), updatedAt: new Date(now) }).where(eq(tripWeather.tripId, tripId));
      // Newly fetched places tell their zones.
      schedule = scheduleOf(active, activeEntries, data, homeZone);
      plan = planNextCheck(schedule, now);
    } catch (error) {
      if (!(error instanceof WeatherProviderError)) throw error;
      console.warn("[weather] provider failed", tripId, error.message);
      retryAt = now + Math.max(error.retryAfterMs ?? 0, 15 * MINUTE);
    }
  }

  const language = translationLanguageFor(summary.language);
  const alerts: WeatherAlertState = { dayAhead: [...row.alertState?.dayAhead ?? []], nowcast: row.alertState?.nowcast ?? null };
  const sends: { alert: { title: string; body: string }; collapseId: string }[] = [];

  // Tomorrow's weather is sent once with the itinerary by the trip reminder workflow.

  const stored = here ? data.locations[here.key] : undefined;
  if (here && stored && now - stored.fetchedAt < NOWCAST_FRESH_MS) {
    const nowcast = assessNowcast(stored.nowcast, stored.current, now);
    if (nowcast) {
      const detected = detectNowcastEvent(alerts.nowcast, nowcast, { date: today!, placeKey: here.key }, now);
      alerts.nowcast = detected.state;
      if (detected.event) sends.push({ alert: nowcastAlertText(detected.event, here.name, language), collapseId: `weather-now:${tripId}` });
    }
  }

  await db.update(tripWeather).set({ alertState: alerts, updatedAt: new Date(now) }).where(eq(tripWeather.tripId, tripId));
  for (const send of sends) await deliver(db, summary.ownerId, payload(summary.ownerId, tripId, send.alert), { collapseId: send.collapseId });

  return retryAt === null ? plan : { done: false, nextAt: Math.min(Math.max(plan.nextAt, retryAt), now + 6 * 60 * MINUTE) };
}
