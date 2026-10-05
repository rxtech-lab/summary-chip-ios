import { ApiError } from "@/lib/http/errors";
import { FlightProviderError, type FlightEndpoint, type FlightProvider, type FlightQuery, type FlightStatus, type ProviderFlight } from "./provider";

/**
 * AeroDataBox (RapidAPI): `GET /flights/number/{number}/{dateLocal}`. 200 is an array of legs,
 * 204 means no such flight that day. Times come as `{ utc: "2026-10-12 01:05Z", local: "2026-10-12 09:05+08:00" }`.
 */

interface AdbTime { utc?: string | null; local?: string | null }
interface AdbMovement {
  airport?: {
    iata?: string | null; icao?: string | null; name?: string | null; shortName?: string | null;
    municipalityName?: string | null; timeZone?: string | null; location?: { lat?: number; lon?: number } | null;
  } | null;
  scheduledTime?: AdbTime | null;
  revisedTime?: AdbTime | null;
  predictedTime?: AdbTime | null;
  runwayTime?: AdbTime | null;
  terminal?: string | null;
  checkInDesk?: string | null;
  gate?: string | null;
  baggageBelt?: string | null;
}
interface AdbFlight {
  number?: string | null;
  status?: string | null;
  codeshareStatus?: string | null;
  isCargo?: boolean | null;
  airline?: { name?: string | null; iata?: string | null; icao?: string | null } | null;
  aircraft?: { model?: string | null } | null;
  departure?: AdbMovement | null;
  arrival?: AdbMovement | null;
}

const STATUS: Record<string, FlightStatus> = {
  Unknown: "unknown",
  Expected: "scheduled",
  CheckIn: "check_in",
  Boarding: "boarding",
  GateClosed: "gate_closed",
  Departed: "departed",
  EnRoute: "en_route",
  Approaching: "approaching",
  Delayed: "delayed",
  Arrived: "landed",
  Canceled: "cancelled",
  CanceledUncertain: "cancelled",
  Diverted: "diverted",
};

function utcIso(time: AdbTime | null | undefined): string | null {
  if (!time?.utc) return null;
  const parsed = Date.parse(time.utc.trim().replace(" ", "T"));
  return Number.isNaN(parsed) ? null : new Date(parsed).toISOString();
}

function wallClock(time: AdbTime | null | undefined): string | null {
  const match = time?.local ? /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})/.exec(time.local.trim()) : null;
  return match ? `${match[1]}T${match[2]}` : null;
}

function text(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed.slice(0, 120) : null;
}

function endpoint(movement: AdbMovement | null | undefined, status: FlightStatus, side: "departure" | "arrival"): FlightEndpoint {
  const airport = movement?.airport;
  const estimatedTime = movement?.revisedTime ?? movement?.predictedTime;
  // The runway time is the actual take-off / touch-down once it happened.
  const happened = side === "departure" ? !["scheduled", "check_in", "boarding", "gate_closed", "delayed", "unknown", "cancelled"].includes(status) : status === "landed";
  const actualTime = happened ? movement?.runwayTime ?? movement?.revisedTime : null;
  const location = airport?.location;
  return {
    iata: text(airport?.iata),
    icao: text(airport?.icao),
    name: text(airport?.shortName) ?? text(airport?.name) ?? text(airport?.iata) ?? "Unknown airport",
    city: text(airport?.municipalityName),
    timeZone: text(airport?.timeZone),
    coordinate: typeof location?.lat === "number" && typeof location?.lon === "number" ? { lat: location.lat, lng: location.lon } : null,
    scheduled: utcIso(movement?.scheduledTime),
    estimated: utcIso(estimatedTime),
    actual: utcIso(actualTime),
    scheduledLocal: wallClock(movement?.scheduledTime),
    estimatedLocal: wallClock(estimatedTime),
    actualLocal: wallClock(actualTime),
    terminal: text(movement?.terminal),
    gate: text(movement?.gate),
    checkInDesk: text(movement?.checkInDesk),
    baggageBelt: side === "arrival" ? text(movement?.baggageBelt) : null,
  };
}

export function normalizeAeroDataBox(raw: AdbFlight): ProviderFlight {
  const status = STATUS[raw.status ?? ""] ?? "unknown";
  return {
    flightNumber: text(raw.number) ?? "",
    status,
    airline: raw.airline?.name ? { name: raw.airline.name.trim(), iata: text(raw.airline.iata), icao: text(raw.airline.icao) } : null,
    aircraft: text(raw.aircraft?.model),
    departure: endpoint(raw.departure, status, "departure"),
    arrival: endpoint(raw.arrival, status, "arrival"),
  };
}

export class AeroDataBoxProvider implements FlightProvider {
  readonly id = "aerodatabox";
  private readonly key: string;
  private readonly host: string;

  constructor(options: { key?: string; host?: string; fetch?: typeof fetch } = {}) {
    const key = options.key ?? process.env.AERODATABOX_API_KEY;
    if (!key) throw new ApiError(503, "FLIGHTS_NOT_CONFIGURED", "Flight tracking is not configured");
    this.key = key;
    this.host = options.host ?? (process.env.AERODATABOX_HOST || "aerodatabox.p.rapidapi.com");
    if (options.fetch) this.fetcher = options.fetch;
  }

  private fetcher: typeof fetch = (input, init) => fetch(input, init);

  async lookup(query: FlightQuery): Promise<ProviderFlight[]> {
    const url = `https://${this.host}/flights/number/${encodeURIComponent(query.flightNumber)}/${query.date}?withAircraftImage=false&withLocation=false&dateLocalRole=Departure`;
    let response: Response;
    try {
      response = await this.fetcher(url, {
        headers: { "x-rapidapi-key": this.key, "x-rapidapi-host": this.host, accept: "application/json" },
        signal: AbortSignal.timeout(15_000),
      });
    } catch {
      throw new FlightProviderError("AeroDataBox could not be reached");
    }
    if (response.status === 204 || response.status === 404) return [];
    // 400: a date outside the range it serves (roughly a year either way), or a malformed number.
    if (response.status === 400) return [];
    if (response.status === 429) {
      const retryAfter = Number(response.headers.get("retry-after"));
      throw new FlightProviderError("AeroDataBox rate limit reached", Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 60_000);
    }
    if (!response.ok) throw new FlightProviderError(`AeroDataBox answered ${response.status}`);
    const body = await response.json().catch(() => null) as AdbFlight[] | null;
    if (!Array.isArray(body)) throw new FlightProviderError("AeroDataBox sent an unexpected answer");
    return body
      .filter((flight) => !flight.isCargo)
      // The operating carrier's row first; codeshare rows describe the same plane.
      .sort((a, b) => Number(b.codeshareStatus === "IsOperator") - Number(a.codeshareStatus === "IsOperator"))
      .map(normalizeAeroDataBox);
  }
}
