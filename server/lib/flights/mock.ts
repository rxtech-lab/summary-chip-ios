import type { FlightProvider, FlightQuery, ProviderFlight } from "./provider";

/**
 * Development stand-in: every flight departs HKG at 09:00 and lands at NRT at 14:30 (UTC+8 / UTC+9)
 * on the asked date, on time. Numbers starting with "XX" don't exist.
 */
export class MockFlightProvider implements FlightProvider {
  readonly id = "mock";

  async lookup(query: FlightQuery): Promise<ProviderFlight[]> {
    if (query.flightNumber.startsWith("XX")) return [];
    const airline = query.flightNumber.slice(0, 2);
    return [{
      flightNumber: `${airline} ${query.flightNumber.slice(2)}`,
      status: "scheduled",
      airline: { name: `${airline} Airlines`, iata: airline, icao: null },
      aircraft: "Airbus A350-900",
      departure: {
        iata: "HKG", icao: "VHHH", name: "Hong Kong", city: "Hong Kong", timeZone: "Asia/Hong_Kong",
        coordinate: { lat: 22.308, lng: 113.918 },
        scheduled: `${query.date}T01:00:00.000Z`, estimated: null, actual: null,
        scheduledLocal: `${query.date}T09:00`, estimatedLocal: null, actualLocal: null,
        terminal: "1", gate: null, checkInDesk: null, baggageBelt: null,
      },
      arrival: {
        iata: "NRT", icao: "RJAA", name: "Tokyo Narita", city: "Tokyo", timeZone: "Asia/Tokyo",
        coordinate: { lat: 35.772, lng: 140.393 },
        scheduled: `${query.date}T05:30:00.000Z`, estimated: null, actual: null,
        scheduledLocal: `${query.date}T14:30`, estimatedLocal: null, actualLocal: null,
        terminal: "2", gate: null, checkInDesk: null, baggageBelt: null,
      },
    }];
  }
}
