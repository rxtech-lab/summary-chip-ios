import { AIRBORNE_STATUSES, type FlightEndpoint, type FlightStatus, type ProviderFlight } from "./provider";

/** When the `trackFlight` workflow checks a flight again, and when it stops. Table: `docs/flights.md`. */

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

/** Live Activities start this long before departure. */
export const LIVE_ACTIVITY_LEAD_MS = 4 * HOUR;
/** Polling stops this long after landing. */
export const LANDED_GRACE_MS = 15 * MINUTE;
/** A flight never reported landed stops being polled this long after its expected arrival. */
const MISSING_LANDING_MS = 12 * HOUR;

function ms(iso: string | null): number | null {
  if (!iso) return null;
  const value = Date.parse(iso);
  return Number.isNaN(value) ? null : value;
}

/** Actual, else estimated, else scheduled. */
export function bestTime(endpoint: FlightEndpoint): number | null {
  return ms(endpoint.actual) ?? ms(endpoint.estimated) ?? ms(endpoint.scheduled);
}

/** Best minus scheduled, in whole minutes (negative = early); null without both. */
export function delayMinutes(endpoint: FlightEndpoint): number | null {
  const scheduled = ms(endpoint.scheduled);
  const best = bestTime(endpoint);
  return scheduled === null || best === null ? null : Math.round((best - scheduled) / MINUTE);
}

export function isAirborne(status: FlightStatus): boolean {
  return AIRBORNE_STATUSES.includes(status);
}

/** When the plane landed: the reported touch-down, else when it was first seen landed. */
export function landedTime(flight: ProviderFlight, previous: number | null, now: number): number | null {
  if (flight.status !== "landed") return null;
  return ms(flight.arrival.actual) ?? previous ?? now;
}

export interface TrackedFlight {
  state: "pending" | "found" | "not_found";
  date: string;
  status: FlightStatus | null;
  departureAt: number | null;
  arrivalAt: number | null;
  landedAt: number | null;
}

export interface TrackingPlan {
  done: boolean;
  /** When to check next (ignored when done). */
  nextAt: number;
}

/** Wakes at the earlier of `now + interval` and the next boundary in `boundaries` still ahead. */
function wake(now: number, interval: number, boundaries: number[] = []): number {
  const ahead = boundaries.filter((at) => at > now);
  return Math.min(now + interval, ...ahead);
}

export function planNextCheck(flight: TrackedFlight, now: number): TrackingPlan {
  const dayStart = Date.parse(`${flight.date}T00:00:00Z`);
  if (flight.state !== "found") {
    // Not known (yet): the provider may only list it closer to the day. Give up once the day is over.
    if (now > dayStart + 2 * DAY) return { done: true, nextAt: now };
    if (flight.state === "pending") return { done: false, nextAt: now + 10 * MINUTE };
    return { done: false, nextAt: wake(now, dayStart - now > 3 * DAY ? DAY : 6 * HOUR, [dayStart - 3 * DAY]) };
  }
  if (flight.status === "cancelled") return { done: true, nextAt: now };
  if (flight.landedAt !== null) {
    const stopAt = flight.landedAt + LANDED_GRACE_MS;
    return now >= stopAt ? { done: true, nextAt: now } : { done: false, nextAt: Math.min(now + 5 * MINUTE, stopAt) };
  }
  const departure = flight.departureAt ?? dayStart;
  const arrival = flight.arrivalAt ?? departure + 6 * HOUR;
  if (now > arrival + MISSING_LANDING_MS) return { done: true, nextAt: now };

  if ((flight.status && isAirborne(flight.status)) || (flight.status === "diverted")) {
    return { done: false, nextAt: now + (arrival - now <= 45 * MINUTE ? 5 * MINUTE : 15 * MINUTE) };
  }
  const until = departure - now;
  const boundaries = [departure - 3 * DAY, departure - DAY, departure - LIVE_ACTIVITY_LEAD_MS];
  if (until > 3 * DAY) return { done: false, nextAt: wake(now, DAY, boundaries) };
  if (until > DAY) return { done: false, nextAt: wake(now, 6 * HOUR, boundaries) };
  if (until > LIVE_ACTIVITY_LEAD_MS) return { done: false, nextAt: wake(now, HOUR, boundaries) };
  return { done: false, nextAt: now + 10 * MINUTE };
}

/** Whether a flight's Live Activity should be running now. */
export function inLiveActivityWindow(flight: TrackedFlight, now: number): boolean {
  if (flight.state !== "found" || flight.status === "cancelled" || flight.departureAt === null) return false;
  if (flight.landedAt !== null) return now < flight.landedAt + LANDED_GRACE_MS;
  return now >= flight.departureAt - LIVE_ACTIVITY_LEAD_MS;
}
