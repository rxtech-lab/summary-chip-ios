# Flight tracking

Flights in a trip are tracked by the backend. The apps never call a flight data provider: they read
what the backend stored. A durable Vercel Workflow per flight polls the provider (AeroDataBox
today), stores the result, sends push alerts on changes and drives the flight's Live Activity.

```
app ── POST /api/v1/flights/lookup ──► backend ──► provider (only if the stored copy is stale)
app ── GET  /api/v1/trips/:id/flights ─► backend (database only)
trip saved ──► syncTripFlights ──► flight_subscriptions ──► trackFlight workflow (one per flight)
trackFlight ──► provider ──► flights row ──► alert pushes + Live Activity pushes
```

## Which flights are tracked

Every time a trip is created or saved (app, agent or MCP), its flights are re-read. A segment is
tracked when `mode = "flight"`, it has `flight.flightNumber`, and it is in the transport's chosen
option (`selectedOptionId`, or the only option) of a transport whose status is not `idea`. Its date
is the local date of `segment.departure`, else the option's `departure`, else `transport.date`.
Removing the segment (or the trip) stops tracking it; a flight with no subscribers left stops polling.

Flights are keyed by `id = <NUMBER>-<YYYY-MM-DD>` (`CX520-2026-10-12`): the flight number upper-cased
without spaces, and the local departure date. Several trips (and users) on one flight share its row,
so the provider is asked once.

## Provider abstraction

`server/lib/flights/provider.ts` defines `FlightProvider` (`lookup({ flightNumber, date })` →
`FlightStatus | null`) and the normalized `FlightStatus`. `aerodatabox.ts` implements it;
`mock.ts` is used in tests and when no key is configured in development. Choose with
`FLIGHT_PROVIDER` (`aerodatabox` | `mock`; default `aerodatabox` when `AERODATABOX_API_KEY` is set).

| Env | Notes |
|---|---|
| `AERODATABOX_API_KEY` | RapidAPI key |
| `AERODATABOX_HOST` | Default `aerodatabox.p.rapidapi.com` |
| `FLIGHT_PROVIDER` | `aerodatabox` or `mock` |

## Polling schedule

Times are relative to the best known departure (actual, else estimated, else scheduled).

| When | Check every |
|---|---|
| More than 3 days before | 24 h |
| 3 days – 24 h before | 6 h |
| 24 h – 4 h before | 1 h |
| 4 h before – departure | 10 min |
| In the air | 15 min; 5 min within 45 min of the expected arrival |
| Landed | until 15 min after landing, then stop |
| Cancelled | stop |
| Not found | daily; stop once the date has passed |
| Never reported landed | stop 12 h after the expected arrival |

A Live Activity is started 4 hours before departure (or right away when the flight is added later).

Each flight has one `trackFlight` run (`server/workflows/track-flight.ts`): a refresh step, then a
durable `sleep` until the next check. `flights.tracking_state` / `tracking_run_id` keep concurrent
saves from starting a second run. Provider failures keep the stored copy and retry in 10 minutes (or
the provider's `Retry-After`). The daily cleanup cron restarts runs that died and deletes looked-up
flights nobody tracks a week after their day.

## API

### `POST /api/v1/flights/lookup`

Body `{ "flightNumber": "CX 520", "date": "2026-10-12" }`. Returns `200 { "flight": Flight }`.
Errors: `404 FLIGHT_NOT_FOUND` (no such flight that day), `400 VALIDATION_ERROR`,
`502 FLIGHT_PROVIDER_FAILED`, `503 FLIGHTS_NOT_CONFIGURED`. A copy refreshed in the last 10 minutes
(or one being tracked) is answered from the database.

### `GET /api/v1/trips/:id/flights`

The trip's tracked flights, from the database only:

```json
{ "flights": [{
  "transportId": "flight-out", "optionId": "cx520", "segmentIndex": 0,
  "flightId": "CX520-2026-10-12", "flightNumber": "CX 520", "date": "2026-10-12",
  "state": "pending | found | not_found",
  "flight": Flight | null
}] }
```

`pending`: not fetched yet (the workflow fetches it within seconds of the save).

### Flight

```json
{
  "id": "CX520-2026-10-12",
  "flightNumber": "CX 520",
  "date": "2026-10-12",
  "status": "scheduled | check_in | boarding | gate_closed | departed | en_route | approaching | delayed | landed | cancelled | diverted | unknown",
  "airline": { "name": "Cathay Pacific", "iata": "CX", "icao": "CPA" },
  "aircraft": "Airbus A350-900",
  "departure": Endpoint,
  "arrival": Endpoint,
  "delayMinutes": 25,
  "arrivalDelayMinutes": 10,
  "updatedAt": "2026-10-12T00:41:12.000Z"
}
```

`airline`, `aircraft`, `delayMinutes` and `arrivalDelayMinutes` may be null. Delays are the best
time minus the scheduled one, in whole minutes (negative = early).

**Endpoint**

```json
{
  "iata": "HKG", "icao": "VHHH", "name": "Hong Kong", "city": "Hong Kong",
  "timeZone": "Asia/Hong_Kong", "coordinate": { "lat": 22.31, "lng": 113.92 },
  "scheduled": "2026-10-12T01:05:00.000Z", "estimated": null, "actual": null,
  "scheduledLocal": "2026-10-12T09:05", "estimatedLocal": null, "actualLocal": null,
  "terminal": "1", "gate": "B12", "checkInDesk": null, "baggageBelt": null
}
```

Every field except `name` may be null. `*Local` is the airport's wall-clock time, `YYYY-MM-DDTHH:mm`.

### Live Activity tokens

- `POST /api/v1/devices/live-activity` `{ "installationId": uuid, "pushToStartToken": hex | null }`:
  the device's ActivityKit push-to-start token (`Activity<FlightActivityAttributes>.pushToStartTokenUpdates`).
  The installation must already be registered with `POST /api/v1/devices`. → `204`.
- `PUT /api/v1/flights/:flightId/live-activity` `{ "installationId": uuid, "token": hex, "environment": "sandbox" | "production" }`:
  a running activity's update token. → `204`. Registering one marks the activity as started for
  the user, so the backend doesn't push-to-start another.
- `DELETE /api/v1/flights/:flightId/live-activity` `{ "installationId": uuid }` → `204`.

## Pushes

**Alerts** go to every device of each subscriber (`apns-push-type: alert`):

```json
{ "aps": { "alert": { "title": "CX 520 delayed", "body": "Now departs 09:35 (+30 min) from HKG" }, "sound": "default", "thread-id": "CX520-2026-10-12" },
  "summaryId": "<tripId>", "tripId": "<tripId>", "userId": "<ownerId>", "flightId": "CX520-2026-10-12" }
```

Sent for: a departure delay of 15+ minutes (and again when it moves by 15+ minutes), an earlier
departure, a new or changed terminal or gate, check-in, boarding, departure, landing, a baggage belt,
a cancellation and a diversion. Texts are in the trip's language (en, zh-Hans, zh-Hant).

**Live Activity** pushes (`apns-push-type: liveactivity`, topic `<bundle id>.push-type.liveactivity`):

- start (push-to-start): `aps.event = "start"`, `"attributes-type": "FlightActivityAttributes"`,
  `attributes`, `content-state`, an `alert`, and `"input-push-token": 1`.
- update: `aps.event = "update"`, `content-state` (and an `alert` for the changes above).
- end: `aps.event = "end"`, `content-state`, `dismissal-date` = 15 min after landing (30 min after the
  last check when the flight was cancelled or stopped being tracked).

```swift
struct FlightActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String            // Flight.status
        var departureScheduled: Double // Unix seconds
        var departureBest: Double      // actual ?? estimated ?? scheduled
        var arrivalScheduled: Double
        var arrivalBest: Double
        var departureTerminal: String?
        var departureGate: String?
        var arrivalTerminal: String?
        var arrivalGate: String?
        var baggageBelt: String?
        var delayMinutes: Int
        var updatedAt: Double
    }
    var flightId: String
    var tripId: String
    var flightNumber: String
    var airlineName: String?
    var fromIATA: String
    var toIATA: String
    var fromCity: String?
    var toCity: String?
}
```

Dates are Unix seconds (`Double`), not `Date`: ActivityKit decodes pushed JSON with the default
decoder, which reads `Date` as seconds since 2001.
