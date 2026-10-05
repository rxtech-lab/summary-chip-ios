import type { ProviderFlight } from "./provider";
import { bestTime, delayMinutes } from "./schedule";

/**
 * ActivityKit payloads for the flight Live Activity. Field names match the app's
 * `FlightActivityAttributes` exactly; dates are Unix seconds (`docs/flights.md`).
 */

export interface FlightContentState {
  status: string;
  departureScheduled: number;
  departureBest: number;
  arrivalScheduled: number;
  arrivalBest: number;
  departureTerminal: string | null;
  departureGate: string | null;
  arrivalTerminal: string | null;
  arrivalGate: string | null;
  baggageBelt: string | null;
  delayMinutes: number;
  updatedAt: number;
}

export interface FlightActivityAttributes {
  flightId: string;
  tripId: string;
  flightNumber: string;
  airlineName: string | null;
  fromIATA: string;
  toIATA: string;
  fromCity: string | null;
  toCity: string | null;
}

const seconds = (ms: number) => Math.floor(ms / 1000);

export function flightContentState(flight: ProviderFlight, now: number): FlightContentState {
  const scheduledOrBest = (iso: string | null, best: number | null) => (iso ? Date.parse(iso) : null) ?? best ?? now;
  const departureBest = bestTime(flight.departure) ?? now;
  const arrivalBest = bestTime(flight.arrival) ?? departureBest;
  return {
    status: flight.status,
    departureScheduled: seconds(scheduledOrBest(flight.departure.scheduled, departureBest)),
    departureBest: seconds(departureBest),
    arrivalScheduled: seconds(scheduledOrBest(flight.arrival.scheduled, arrivalBest)),
    arrivalBest: seconds(arrivalBest),
    departureTerminal: flight.departure.terminal,
    departureGate: flight.departure.gate,
    arrivalTerminal: flight.arrival.terminal,
    arrivalGate: flight.arrival.gate,
    baggageBelt: flight.arrival.baggageBelt,
    delayMinutes: delayMinutes(flight.departure) ?? 0,
    updatedAt: seconds(now),
  };
}

/** Whether two states differ in anything but `updatedAt` (an update push is worth sending). */
export function contentStateChanged(a: FlightContentState | null, b: FlightContentState): boolean {
  if (!a) return true;
  return JSON.stringify({ ...a, updatedAt: 0 }) !== JSON.stringify({ ...b, updatedAt: 0 });
}

export function flightActivityAttributes(flightId: string, tripId: string, flight: ProviderFlight): FlightActivityAttributes {
  return {
    flightId,
    tripId,
    flightNumber: flight.flightNumber,
    airlineName: flight.airline?.name ?? null,
    fromIATA: flight.departure.iata ?? flight.departure.icao ?? "",
    toIATA: flight.arrival.iata ?? flight.arrival.icao ?? "",
    fromCity: flight.departure.city,
    toCity: flight.arrival.city,
  };
}

type Alert = { title: string; body: string };

export function startPayload(attributes: FlightActivityAttributes, state: FlightContentState, alert: Alert, now: number) {
  return {
    aps: {
      timestamp: seconds(now),
      event: "start",
      "content-state": state,
      "attributes-type": "FlightActivityAttributes",
      attributes,
      alert,
      "input-push-token": 1,
    },
  };
}

export function updatePayload(state: FlightContentState, alert: Alert | null, now: number) {
  return {
    aps: {
      timestamp: seconds(now),
      event: "update",
      "content-state": state,
      // Shown as stale when no update came for an hour.
      "stale-date": seconds(now) + 3600,
      ...(alert ? { alert: { ...alert, sound: "default" } } : {}),
    },
  };
}

export function endPayload(state: FlightContentState, dismissAt: number, now: number) {
  return {
    aps: {
      timestamp: seconds(now),
      event: "end",
      "content-state": state,
      "dismissal-date": seconds(dismissAt),
    },
  };
}
