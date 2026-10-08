/** When the `trackTripWeather` workflow checks a trip again, and when it stops. Table: `docs/weather.md`. */

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

/** Providers forecast today plus 15 days. */
export const FORECAST_DAYS = 16;
/** A full refresh (every location) at most this often; checks in between only fetch the nowcast place. */
export const FULL_REFRESH_MS = 3 * HOUR;
/** During the trip the next 30 minutes are checked this often, between 07:00 and 22:00 trip time. */
export const NOWCAST_INTERVAL_MS = 15 * MINUTE;
export const NOWCAST_FROM_MINUTES = 7 * 60;
export const NOWCAST_UNTIL_MINUTES = 22 * 60;
/** Tomorrow's weather is sent at 20:00 trip time the day before. */
export const DAY_AHEAD_MINUTES = 20 * 60;

export function addDays(date: string, days: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * DAY).toISOString().slice(0, 10);
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let cached = formatters.get(timeZone);
  if (!cached) {
    try {
      cached = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
    } catch {
      return formatter("UTC");
    }
    formatters.set(timeZone, cached);
  }
  return cached;
}

/** Whether `value` is an IANA time zone this runtime knows ("Asia/Tokyo"). */
export function isTimeZone(value: string): boolean {
  try {
    new Intl.DateTimeFormat("en", { timeZone: value });
    return true;
  } catch {
    return false;
  }
}

/** The trip's wall clock at `at`: its date and minutes since midnight. */
export function localParts(at: number, timeZone: string): { date: string; minutes: number } {
  const parts = Object.fromEntries(formatter(timeZone).formatToParts(new Date(at)).map((part) => [part.type, part.value]));
  return { date: `${parts.year}-${parts.month}-${parts.day}`, minutes: Number(parts.hour) * 60 + Number(parts.minute) };
}

/** `date` at `minutes` past midnight in `timeZone` → Unix ms (DST gaps resolve forward). */
export function zonedTime(date: string, minutes: number, timeZone: string): number {
  const wall = Date.parse(`${date}T00:00:00Z`) + minutes * MINUTE;
  let guess = wall;
  for (let pass = 0; pass < 2; pass += 1) {
    const local = localParts(guess, timeZone);
    const shown = Date.parse(`${local.date}T00:00:00Z`) + local.minutes * MINUTE;
    guess += wall - shown;
  }
  return guess;
}

/** The zones the traveller is in on a trip date: of the day's first place (morning) and last place (night). */
export interface DayZones {
  morning: string;
  evening: string;
}

export interface WeatherSchedule {
  startDate: string;
  endDate: string;
  /** The trip's own zone, for dates whose places' zones aren't known (yet). */
  timeZone: string;
  /** Per trip date, where the traveller is (`tripZones`). */
  zones?: Record<string, DayZones>;
  /** Where the traveller is before the trip (their device's zone), for the evening before the first day. */
  homeZone?: string | null;
}

export interface WeatherPlan {
  done: boolean;
  /** When to check next (ignored when done). */
  nextAt: number;
}

export function zonesOn(trip: WeatherSchedule, date: string): DayZones {
  return trip.zones?.[date] ?? { morning: trip.timeZone, evening: trip.timeZone };
}

function tripDates(trip: WeatherSchedule): string[] {
  const out: string[] = [];
  for (let date = trip.startDate; date <= trip.endDate && out.length < 400; date = addDays(date, 1)) out.push(date);
  return out;
}

/**
 * When tomorrow's-weather alerts go out: 20:00 on the evening before each day, where the traveller
 * spends that evening (the previous day's last place; before the trip, their device's zone). Each
 * can still go out until midnight there (`until`).
 */
export function dayAheadTimes(trip: WeatherSchedule): { date: string; at: number; until: number; timeZone: string }[] {
  return tripDates(trip).map((date) => {
    const timeZone = date === trip.startDate ? trip.homeZone || zonesOn(trip, date).morning : zonesOn(trip, addDays(date, -1)).evening;
    return { date, at: zonedTime(addDays(date, -1), DAY_AHEAD_MINUTES, timeZone), until: zonedTime(date, 0, timeZone), timeZone };
  });
}

/** A trip day's nowcast window: 07:00 where the day starts until 22:00 where it ends. */
function nowcastWindow(trip: WeatherSchedule, date: string): { from: number; until: number } {
  const zones = zonesOn(trip, date);
  return { from: zonedTime(date, NOWCAST_FROM_MINUTES, zones.morning), until: zonedTime(date, NOWCAST_UNTIL_MINUTES, zones.evening) };
}

/** The trip date whose daytime it is now (the next 30 minutes are watched), or null. */
export function nowcastDate(trip: WeatherSchedule, now: number): string | null {
  let found: string | null = null;
  for (const date of tripDates(trip)) {
    const window = nowcastWindow(trip, date);
    if (now >= window.from && now < window.until) found = date;
  }
  return found;
}

/** Whether the next 30 minutes are watched now: during the trip, in the daytime where the traveller is. */
export function inNowcastWindow(trip: WeatherSchedule, now: number): boolean {
  return nowcastDate(trip, now) !== null;
}

/** Whether any day of the trip is within the forecast range (worth fetching). */
export function inForecastRange(trip: WeatherSchedule, now: number): boolean {
  const today = localParts(now, trip.timeZone).date;
  return trip.endDate >= today && trip.startDate <= addDays(today, FORECAST_DAYS - 1);
}

export function planNextCheck(trip: WeatherSchedule, now: number): WeatherPlan {
  // Over once the last day has ended where the traveller is.
  const tripEnd = zonedTime(addDays(trip.endDate, 1), 0, zonesOn(trip, trip.endDate).evening);
  if (now >= tripEnd) return { done: true, nextAt: now };
  const boundaries = [
    ...dayAheadTimes(trip).map((entry) => entry.at),
    // The first nowcast check of each trip day.
    ...tripDates(trip).map((date) => nowcastWindow(trip, date).from),
    // Forecasts start covering the trip.
    zonedTime(addDays(trip.startDate, -(FORECAST_DAYS - 1)), 0, trip.timeZone),
  ].filter((at) => at > now);
  const interval = inNowcastWindow(trip, now) ? NOWCAST_INTERVAL_MS
    : inForecastRange(trip, now) ? FULL_REFRESH_MS
    : DAY;
  const nextAt = Math.min(now + interval, ...boundaries);
  return { done: false, nextAt: Math.max(nextAt, now + MINUTE) };
}
