import { ApiError } from "@/lib/http/errors";

/**
 * Flight data behind one interface, so the provider can change without touching tracking.
 * Providers normalize their answers into `ProviderFlight`; the rest of the backend never sees
 * provider-specific JSON. Spec: `docs/flights.md`.
 */

export const FLIGHT_STATUSES = [
  "scheduled", "check_in", "boarding", "gate_closed", "departed", "en_route", "approaching",
  "delayed", "landed", "cancelled", "diverted", "unknown",
] as const;
export type FlightStatus = (typeof FLIGHT_STATUSES)[number];

/** Statuses once the plane has left the gate, before it lands. */
export const AIRBORNE_STATUSES: readonly FlightStatus[] = ["departed", "en_route", "approaching"];

export interface FlightEndpoint {
  iata: string | null;
  icao: string | null;
  name: string;
  city: string | null;
  timeZone: string | null;
  coordinate: { lat: number; lng: number } | null;
  /** UTC instants, ISO 8601. */
  scheduled: string | null;
  estimated: string | null;
  actual: string | null;
  /** The airport's wall-clock time, `YYYY-MM-DDTHH:mm`. */
  scheduledLocal: string | null;
  estimatedLocal: string | null;
  actualLocal: string | null;
  terminal: string | null;
  gate: string | null;
  checkInDesk: string | null;
  baggageBelt: string | null;
}

export interface ProviderFlight {
  /** As the provider prints it, e.g. "CX 520". */
  flightNumber: string;
  status: FlightStatus;
  airline: { name: string; iata: string | null; icao: string | null } | null;
  aircraft: string | null;
  departure: FlightEndpoint;
  arrival: FlightEndpoint;
}

export interface FlightQuery {
  /** Normalized: upper-case, no spaces ("CX520"). */
  flightNumber: string;
  /** Local departure date, `YYYY-MM-DD`. */
  date: string;
}

export interface FlightProvider {
  readonly id: string;
  /** Every leg flying under this number that day (several for multi-leg flights); empty when there is none. */
  lookup(query: FlightQuery): Promise<ProviderFlight[]>;
}

/** The provider failed (network, quota, bad answer): try again later. Not "no such flight". */
export class FlightProviderError extends Error {
  constructor(message: string, public readonly retryAfterMs?: number) {
    super(message);
    this.name = "FlightProviderError";
  }
}

let override: FlightProvider | undefined;

export function setFlightProviderForTests(provider?: FlightProvider): void {
  override = provider;
}

/** `FLIGHT_PROVIDER` picks one; by default AeroDataBox when its key is set, else the mock outside production. */
export async function getFlightProvider(): Promise<FlightProvider> {
  if (override) return override;
  const choice = process.env.FLIGHT_PROVIDER?.trim() || (process.env.AERODATABOX_API_KEY ? "aerodatabox" : "");
  if (choice === "aerodatabox") {
    const { AeroDataBoxProvider } = await import("./aerodatabox");
    return new AeroDataBoxProvider();
  }
  if (choice === "mock" || (!choice && process.env.NODE_ENV !== "production")) {
    const { MockFlightProvider } = await import("./mock");
    return new MockFlightProvider();
  }
  throw new ApiError(503, "FLIGHTS_NOT_CONFIGURED", "Flight tracking is not configured");
}
