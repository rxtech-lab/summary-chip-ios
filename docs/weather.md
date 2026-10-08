# Trip weather

The backend keeps a weather forecast for every trip that isn't over yet. The apps never call a
weather provider: they read what the backend stored. A durable Vercel Workflow per trip fetches the
forecasts, stores them, and sends the trip owner two kinds of alerts:

- **Tomorrow's weather**: at 20:00 on the evening before each day of the trip, where you spend that
  evening.
- **The next 30 minutes**: during the trip, from 07:00 to 22:00 where you are. You get an alert when the
  weather where you are turns bad, gets worse, changes to a different kind of bad weather, or clears up.

```
trip saved ──► syncTripWeather ──► trip_weather row ──► trackTripWeather workflow (one per trip)
trackTripWeather ──► provider ──► trip_weather.data ──► alert pushes
app ── GET /api/v1/trips/:id/weather ──► backend (database only)
```

## Time zones

Alert times follow the traveller's local time, not the server's clock or one fixed zone for the
whole trip:

- **Each place's zone.** Open-Meteo returns each place's IANA zone (`timezone=auto`). On each trip
  date, the **morning zone** is the zone of the day's first place. The **night zone** is the zone of
  its last place, where the night is spent.
- **Before the trip, the device's zone.** The app sends `TimeZone.current.identifier` with every push
  registration (`POST /api/v1/devices`, on every launch and activation). The owner's most recently
  registered device decides.
- **Fallback.** The trip's `timeZone` applies until a place has been fetched, and for owners whose
  app hasn't sent a zone.

Which zone each alert and check uses:

| What | When, local time |
|---|---|
| Tomorrow's weather, first day | 20:00 on the evening before, in the device's zone (else the first day's morning zone) |
| Tomorrow's weather, later days | 20:00 on the previous day, in that day's night zone |
| Next-30-minutes checks | 07:00 in the day's morning zone until 22:00 in its night zone |
| A moment's `time` | The wall clock at the moment's place |
| End of tracking | Midnight after the last day, in its night zone |

For example, take a trip that flies from Tokyo to London on day 2:

- Day 2 is watched from 07:00 in Tokyo until 22:00 in London.
- Day 3's forecast arrives at 20:00 London time.

## Where the weather is about

**A day's places.** The weather for a day covers up to 3 of its places, in this order:

1. its `route.placeIds`;
2. the `placeId`s of its moments;
3. its hotel's place (`stayId` → `hotel.placeId`).

Places less than 15 km apart share one forecast.

**Days that name no place.** The day takes the last place of the previous day, which is where you
slept. If there is no previous place, it takes the trip's first major place, else its first place.

**Trips without day records.** These get one entry per date, at that fallback place.

**Forecast keys.** Forecasts are keyed by coordinates rounded to 2 decimals (`35.01,135.77`).

**Plan options.** Stored forecasts cover the days of every plan option, so switching options shows
the right weather at once. Alerts and `now` follow the reader's own picks. For alerts, the reader is
the trip owner.

**Where you are now.** For the next-30-minutes check, this is the place of today's latest moment that
starts within the next 30 minutes. If there is no such moment, it is the day's first place.

## Provider

`server/lib/weather/provider.ts` defines `WeatherProvider` (`forecast(points)` → one
`LocationForecast` per point). A `LocationForecast` holds:

- 16 days of daily values;
- current conditions;
- 15-minute nowcast slots for the next 3 hours.

`open-meteo.ts` implements it. It sends one request per 50 places, with comma-separated
coordinates and `timezone=auto`. `mock.ts` is used in tests and with `WEATHER_PROVIDER=mock`.

| Env | Notes |
|---|---|
| `OPEN_METEO_API_KEY` | Optional. Open-Meteo's free API is for non-commercial use. With a key, requests go to `customer-api.open-meteo.com`. |
| `WEATHER_PROVIDER` | `open-meteo` (default) or `mock` |

## Checks

Each trip has one `trackTripWeather` run (`server/workflows/track-trip-weather.ts`). Each check is a
refresh step followed by a durable `sleep`. How often it checks:

| When | Check every |
|---|---|
| More than 15 days before the trip | 24 h (nothing to fetch yet) |
| Forecast range, before the trip and at night | 3 h |
| During the trip, 07:00–22:00 local time (see [Time zones](#time-zones)) | 15 min |
| After the trip | stop |

Some times always get a check, even between those intervals: 20:00 on the evening before each day,
and 07:00 on each trip day.

**What a check fetches.** A full refresh fetches every place, at most every 3 hours. The checks in
between fetch only the place you are at now.

**Provider failures.** The stored forecast stays, and the check is retried after 15 minutes, or after
the provider's `Retry-After`.

**Restarts.** Every trip save makes sure a run is going, so a trip moved to later dates starts again.
A save also fetches any place the forecast doesn't cover yet. The daily cleanup cron restarts runs
that died. Deleting a trip deletes its row, and its run stops at the next check.

## Conditions

WMO weather codes map to these conditions:

`clear | partly_cloudy | cloudy | fog | drizzle | rain | heavy_rain | freezing_rain | snow | heavy_snow | thunderstorm | strong_wind`

`strong_wind` means gusts of 60 km/h or more, when the weather code says nothing worse.

Severity:

| Condition | Severity |
|---|---|
| clear, partly cloudy, cloudy | 0 |
| fog, drizzle | 1 |
| rain, snow, strong wind | 2 ("bad") |
| heavy rain, freezing rain, heavy snow | 3 |
| thunderstorm | 4 |

## Alerts

Alerts go to every device of the trip owner (`apns-push-type: alert`), in the trip's language
(en, zh-Hans or zh-Hant):

```json
{ "aps": { "alert": { "title": "Rain soon in Nara", "body": "Rain expected from 11:45. Plan for shelter or cover." },
           "sound": "default", "thread-id": "weather:<tripId>" },
  "summaryId": "<tripId>", "tripId": "<tripId>", "userId": "<ownerId>", "kind": "weather" }
```

### Tomorrow's weather

Collapse ID: `weather:<tripId>:<date>`.

The alert lists the day's first 2 places with their condition, temperature range and chance of
rain. It may add tips: an umbrella, strong gusts, heat, or high UV. Example: "Tomorrow in Kyoto:
Rain" / "Kyoto: Rain, 14–21°C, 80% chance of rain · Nara: Cloudy, 15–22°C. Bring an umbrella."

Each date's alert is sent once. It can go out any time on the evening before the day, from 20:00
until midnight in the zone that evening is spent in. If the forecast is missing at that time, the
backend tries again at the next check that evening.

### The next 30 minutes

Collapse ID: `weather-now:<tripId>`.

The check compares the current 15-minute slot with the worst weather starting in the next 30 minutes.

| Event | When it's sent |
|---|---|
| `now` | Bad weather is already there and hasn't been announced |
| `starts` | Bad weather begins within 30 minutes |
| `worsens` | The weather becomes more severe than what was announced |
| `changes` | A different bad weather of the same severity, such as rain turning to snow |
| `clears` | An announced spell ends |

What has been announced is tracked per trip date and per place. A new day, or moving to another
place, starts over.

Weather alerts come at most every 20 minutes. A thunderstorm alert is always sent, even within that
time.

## API

### `GET /api/v1/trips/:id/weather`

Readers of the trip can call this. It returns `404` for others. The answer comes from the database
only:

```json
{
  "updatedAt": "2026-10-12T03:00:00.000Z",
  "days": [{
    "dayId": "d1", "date": "2026-10-12",
    "locations": [{ "placeId": "kyoto", "name": "Kyoto", "forecast": {
      "date": "2026-10-12", "condition": "rain", "weatherCode": 61, "high": 21.4, "low": 14.2,
      "precipitationChance": 80, "precipitation": 6.1, "windMax": 20, "gustsMax": 41, "uvIndexMax": 3,
      "sunrise": "2026-10-12T05:49", "sunset": "2026-10-12T17:21"
    } }]
  }],
  "now": {
    "dayId": "d1", "placeId": "kyoto", "name": "Kyoto", "condition": "cloudy", "temperature": 18.2,
    "next30Minutes": { "condition": "rain", "at": "2026-10-12T03:30:00.000Z" }
  }
}
```

**`forecast`.** This is `null` beyond the 16-day range, or until the place has been fetched (the
apps check again a few seconds after a save).

**`now`.** This is only present during the trip's daytime window, when the stored nowcast is less
than 30 minutes old.

**`dayId`.** This is `null` only for trips without day records.

**Units.** °C, mm and km/h. The apps convert them to the user's locale.

## Apps

- **Day cards** show the forecast's condition and high in the header. Tapping it opens the day's
  weather sheet.
- **The day's details sheet** has a Weather section.
- **During the trip**, a banner at the top of the diary shows the weather now and what the next
  30 minutes bring.
- **Refreshes.** The apps re-read the weather on open, after saves and agent edits, on return to the
  foreground, and when a trip push arrives.
