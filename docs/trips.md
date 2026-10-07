# Trip diaries

A trip is a library item (`summaries.kind = "trip"`) whose structured diary lives in the `trips`
table as one JSON **TripDocument** (v1). The zod schema in `server/lib/contracts/trip.ts` is the
source of truth; `Packages/SummaryKit/Sources/SummaryKit/Models/Trip.swift` mirrors it. The app
renders any TripDocument the same way: the diary scroll drives the map camera and route progress.

Records point at each other by stable string ids, so an agent or the app can upsert or delete one
record without rewriting the rest. Every referenced id must exist, and ids are unique within their
collection; the server refuses documents that break this (`tripIntegrityIssues`).

## Conventions

| Thing | Format |
|---|---|
| Dates | `YYYY-MM-DD` |
| Clock times (`moment.time`, `hotel.checkInTime`) | `HH:mm` |
| Departure / arrival (`option`, `segment`) | Local wall-clock time at that place, `YYYY-MM-DDTHH:mm`, no offset |
| Money | `{ amount: number ≥ 0, currency: "JPY" }` (ISO 4217) |
| Coordinates | `{ lat, lng }` (WGS 84) |
| Ids | 1–80 characters; new records get short kebab-case ids (`hotel-hakodate-kokusai`) |
| Optional fields | May be omitted or `null` |

## Document

| Field | Type | Notes |
|---|---|---|
| `version` | `1` | |
| `title` | string ≤ 200 | Also the library item's title |
| `subtitle`, `intro` | string? | `intro` becomes the library item's summary |
| `startDate`, `endDate` | date | `endDate ≥ startDate` |
| `timeZone` | IANA zone, default `UTC` | The zone local times are in; "today" is computed in it |
| `currency` | ISO 4217, default `USD` | The trip's default currency |
| `places` | `Place[]` ≤ 500 | |
| `days` | `Day[]` ≤ 366 | Kept sorted by date |
| `transports` | `Transport[]` ≤ 500 | Kept sorted by date |
| `hotels` | `Hotel[]` ≤ 200 | Kept sorted by check-in |
| `expenses` | `Expense[]` ≤ 2000 | |
| `notes` | `{ id, title, text }[]` ≤ 100 | |
| `sources` | `{ title, url }[]` ≤ 200 | Pages the trip was built from |
| `views` | `View[]` ≤ 50 | Custom JSON-rendered UIs (see below) |
| `plans` | `Plan[]` ≤ 50 | Alternative plans: route 1 / route 2… for the trip or a day (see below) |

**Place** — `id`, `name`, `kind` (`city | station | airport | hotel | poi | port`, default `poi`),
`coordinate`, `address?`, `note?`, `major` (bool, default false: drawn larger on the map), and guidebook
details: `description?` (what it is, why go), `photos[]` ≤ 12 `{ url, caption?, credit?, sourceUrl? }`
(direct **https** image URLs only), `hours?` ("9:00–17:00, closed Mondays"), `visitDuration?` ("1–2 h"),
`pricing[]` ≤ 30 `{ label, price?: Money, note? }` (no `price` = free), `website?`, `phone?`. The apps show
them in the place's detail sheet with a Directions button: tapping the GPS location opens Maps (or Google
Maps) with directions to the coordinate.

**Day** — `id`, `date`, `title`, `short?` ("成田 → 千叶"), `blurb?`, `highlight` (bool),
`route?` `{ kind: out | side | back | ferry | airport | stay, placeIds[], path?: Coordinate[], summary? }`
(clients connect `placeIds` in order when there is no `path`), `moments[]`
`{ slot: morning | afternoon | evening | night, time?, text, placeId? }`, `tip?`, `stayId?` (a hotel),
`transportIds[]`.

**Transport** — `id`, `date`, `label`, `status` (`idea | planned | booked`, default `planned`),
`selectedOptionId?`, `options[]` (1–10):

- **Option** — `id`, `label`, `departure?`, `arrival?`, `duration?` (free text), `fare?`, `warning?`,
  `notes[]`, `segments[]`.
- **Segment** — `mode` (`train | flight | ferry | bus | car | walk | other`), `fromPlaceId?`,
  `toPlaceId?`, `fromName`, `toName`, `departure?`, `arrival?`, `price?`, `sourceUrl?`, and
  - `train?` `{ operator?, line?, name? ("はやぶさ"), number? ("5", "544F"), category: shinkansen | limited_express | rapid | local | other, carNumber?, seat?, seatClass? }`
  - `flight?` `{ airline?, flightNumber, fromIATA?, toIATA?, terminal?, gate?, seat?, seatClass?, bookingRef? }`
  - `seatClass`: `reserved | non_reserved | green | gran_class | economy | premium_economy | business | first`.

**Hotel** — `id`, `name`, `placeId?`, `address?`, `checkIn`, `checkOut` (dates, `checkOut ≥ checkIn`),
`checkInTime?`, `confirmation?`, `price?`, `url?`, `status` (default `planned`).

**Expense** — `id`, `date?`, `dayId?`, `category` (`transport | lodging | food | activity | shopping | pass | other`),
`title`, `amount`, `paid` (default false), `coveredByExpenseId?` (the `pass` expense that covers it;
covered rows don't add to totals), `linkedId?` (the transport or hotel it pays for).

## Custom views

A **View** is a small native UI described as JSON, in the style of Vercel's json-render: `id`,
`title`, `dayId?` (without it the view is listed in the trip's **Views** pane; with it, it also shows
inside that day's card) and `spec: { root, elements }`. `elements` maps element ids to
`{ type, props, children? }`; `root` is the top element's id. Containers list children by id, and each
id is used once (no cycles). The catalog (`server/lib/contracts/trip-view.ts`) is closed, so an unknown
`type` is refused:

| Type | Props | Children |
|---|---|---|
| `Stack` | `direction` (`vertical`/`horizontal`), `gap` (`none`/`small`/`medium`/`large`) | yes |
| `Grid` | `columns` 1–4 | yes |
| `Card` | `title?`, `subtitle?`, `tone?` | yes |
| `Disclosure` | `title`, `expanded?` (collapsed by default) | yes |
| `Heading` | `text`, `level` 1–3 | |
| `Text` | `text`, `tone?`, `size?` (`small`/`body`/`large`), `weight?` | |
| `Badge` | `text`, `tone?` | |
| `Stat` | `label`, `value`, `format?`, `currency?`, `detail?`, `tone?` | |
| `Callout` | `title?`, `text`, `tone` (`info`/`tip`/`warning`/`success`) | |
| `KeyValue` | `items: [{ label, value, format?, currency?, tone? }]` | |
| `List` | `items: string[]`, `ordered?` | |
| `Table` | `caption?`, `columns: [{ key, label, align?, format?, currency?, total? }]`, `rows: [{ cells: { key: value \| { value, detail?, tone? } }, style? }]`, `totalLabel?` | |
| `BarChart` | `title?`, `format?`, `currency?`, `items: [{ label, value, detail?, tone? }]` | |
| `Divider`, `Link` (`title`, `url`) | | |
| `Image` | `url` (https), `caption?`, `credit?`, `aspect?` (`wide` 16:9 default / `square` / `portrait`) | |
| `Gallery` | `images: [{ url, caption?, credit? }]` (1–12, https) | |
| `Place` | `placeId`: a card of the trip's place with its photo, description, hours, a price and Directions; draws nothing when the place is gone | |

Values are strings, numbers or null; `format` (`text`/`number`/`money`/`percent`) formats numbers
(money in `currency`, else the trip's). A column with `total: true` gets a summed total row. Tones:
`default`, `muted`, `accent`, `positive`, `negative`, `warning`. The apps draw a table as a grid when
it fits and as one block per row on narrow screens. The Northbound fixture has two examples: a JR pass
vs IC card comparison (`view-jr-pass-vs-ic`) and a day view (`view-pass-day-1`).

A `PUT` whose document has no `views` key (an app build from before views) keeps the saved views; one
without `plans` keeps the saved plans and the records' `planOptionId`s.

## Plans (alternatives)

A **Plan** offers alternatives the reader picks between: `id`, `title`, `scope` (`trip` | `day`, default
`trip`), `date?` (required for `day`, within the trip), `options[]` (2–6 `{ id, label, summary? }`; option ids
are unique across all plans) and `defaultOptionId?`.

Days, transports, hotels, expenses, notes and views take an optional `planOptionId`. Untagged records are
shared by every option; a tagged one only shows while its option is picked. A day plan's alternatives are
separate day records on the plan's date (one per option, e.g. `day-3-route-1`, `day-3-route-2`; the server
refuses a tagged day on another date). A trip plan's options can each carry their own days, hotels and
transport for the dates they differ.

Each reader's pick is saved for them (`trip_plan_selections`), not in the document: `PUT
/api/v1/trips/:id/plan-selections` `{ planId, optionId }` (`null` = back to the default) by anyone who can read
the trip, or MCP `choose_plan_option`. It doesn't change the revision or send "Trip updated". `GET` returns
`planSelections` (plan id → option id); a plan without a valid pick follows `defaultOptionId`, else its first
option. The apps, calendar sync and the PDF export show the trip as the reader follows it
(`activeTripDocument` / `TripDocument.following`): records of the other options are left out, with the places
only they visit. The apps draw a trip plan's picker in the diary's **Plans** section and a day plan's above its
day.

## Example

```json
{
  "version": 1,
  "title": "Kyoto weekend",
  "startDate": "2026-11-06", "endDate": "2026-11-08",
  "timeZone": "Asia/Tokyo", "currency": "JPY",
  "places": [
    { "id": "kix", "name": "Kansai Airport", "kind": "airport", "coordinate": { "lat": 34.4347, "lng": 135.244 } },
    { "id": "kyoto", "name": "Kyoto", "kind": "city", "coordinate": { "lat": 35.0116, "lng": 135.7681 }, "major": true }
  ],
  "days": [{
    "id": "day-1", "date": "2026-11-06", "title": "Arrive",
    "route": { "kind": "airport", "placeIds": ["kix", "kyoto"] },
    "moments": [{ "slot": "evening", "time": "18:00", "text": "Check in, dinner on Pontocho", "placeId": "kyoto" }],
    "stayId": "ryokan", "transportIds": ["haruka"]
  }],
  "transports": [{
    "id": "haruka", "date": "2026-11-06", "label": "KIX → Kyoto", "status": "booked", "selectedOptionId": "haruka-36",
    "options": [{
      "id": "haruka-36", "label": "Haruka 36", "departure": "2026-11-06T15:16", "arrival": "2026-11-06T16:35",
      "fare": { "amount": 3640, "currency": "JPY" },
      "segments": [{
        "mode": "train", "fromPlaceId": "kix", "toPlaceId": "kyoto", "fromName": "Kansai Airport", "toName": "Kyoto",
        "departure": "2026-11-06T15:16", "arrival": "2026-11-06T16:35",
        "train": { "operator": "JR West", "name": "Haruka", "number": "36", "category": "limited_express", "carNumber": "3", "seat": "7A", "seatClass": "reserved" }
      }]
    }]
  }],
  "hotels": [{ "id": "ryokan", "name": "Ryokan Yachiyo", "placeId": "kyoto", "checkIn": "2026-11-06", "checkOut": "2026-11-08", "status": "booked" }],
  "expenses": [{ "id": "haruka-fare", "category": "transport", "title": "Haruka", "amount": { "amount": 3640, "currency": "JPY" }, "linkedId": "haruka", "dayId": "day-1", "paid": true }],
  "notes": [], "sources": []
}
```

A full real trip, converted from the hand-built Northbound Japan site by
`server/scripts/convert-northbound.ts`, is in `server/tests/fixtures/northbound-trip.json` (11 days,
10 transports with 28 options of train/ferry/bus segments, 6 hotel ideas, a JR pass covering fares).

## Operations

Agents (and the app, for small edits) change a trip with operations applied in order, atomically
(`POST /api/v1/trips/:id/operations`, MCP `update_trip`):

| `op` | Fields | Effect |
|---|---|---|
| `set_meta` | `meta: { title?, subtitle?, intro?, startDate?, endDate?, timeZone?, currency? }` | Changes only the given fields; `null` clears `subtitle`/`intro` |
| `upsert_place` / `upsert_day` / `upsert_transport` / `upsert_hotel` / `upsert_expense` / `upsert_note` / `upsert_view` / `upsert_plan` | `place` / `day` / … / `view` (a full record) | Replaces the record with the same id, or adds it |
| `resolve_plan` | `id`, `optionId` | Settles a plan: that option's records stay (untagged), the other options' records and the plan are deleted |
| `add_source` | `source: { title, url }` | Adds it unless the URL is already listed |
| `update_place` | `id`, `changes` (any place fields but `id`; `null` clears one; `photos`/`pricing` replace their lists), `addPhotos[]` | Patches the place without resending it; new photos go after the existing ones (no duplicate URLs, ≤ 12). Unknown ids are ignored |
| `delete` | `collection` (`places`, `days`, `transports`, `hotels`, `expenses`, `notes`, `views`, `plans`), `id` | Removes it (a plan together with all its options' records) and clears references to it (route place ids, `stayId`, `transportIds`, `linkedId`, `dayId`, `coveredByExpenseId`; a deleted day's views move to the Views pane); unknown ids are ignored |

The result must be a valid document, else `422 TRIP_INVALID` (`details.issues`) and nothing changes.

## Revisions

Every changed document save bumps `revision`; no-op edits keep it. `PUT` requires the revision the client edited, and operations accept
it optionally; a trip that changed since is `409 TRIP_REVISION_CONFLICT` with `details.revision`
(the current one). The app then reloads and tells the user the trip was updated (e.g. by the agent).

## Trip agent

`POST /api/v1/trips/:id/ingest` (the share extension's **Add to trip**) and MCP
`add_to_trip_from_source` read a page or text with the summary pipeline's extractors, then the trip
agent (`server/lib/ai/trip-agent.ts`, the gateway text model with one `apply_operations` tool) turns
it into operations. Each operation is validated on its own (malformed ones are dropped); a result that
leaves the trip invalid is sent back to the agent once with the issues; whatever still doesn't fit is
dropped one operation at a time. A page with a URL is added to `sources`. The agent is charged in
points (`402 TRIP_POINTS_EXHAUSTED` when the balance is empty, checked before anything runs); direct
edits are free. All persisted edits queue a debounced "Trip updated" push with `tripId` for the creator
and signed-in shared-link readers. Vercel Workflow waits five minutes after the last edit, then a
read-only agent summarizes the batch's net changes. See [notifications.md](notifications.md).

## Photos

Photos are referenced by URL. Agents get them three ways: the trip agent is shown the https images of
the page it reads (its preview image and the `<img>`s of its content, without icons), MCP agents can
copy or upload one with `upload_trip_image` (stored in R2, re-encoded without EXIF, lasting URL), and
users paste an image link in the place editor. Only https URLs are accepted.

## PDF export

`GET /api/v1/trips/:id/pdf` (anyone who can open the trip; free) returns the trip as an A4 PDF report:
a cover (title, dates, intro, counts and budget), the itinerary day by day (moments with their places,
transport, stay, tip and the day's views), planning views, places as guidebook entries (photos,
description, hours, prices, website, phone and a Google Maps directions link), stays, transport, the
budget with totals per currency (covered expenses excluded), notes and sources. Every page has the trip's
title and dates in the header and "Page n / m" in the footer; margins are 22 mm top, 18 mm bottom and
16 mm at the sides.

`server/lib/pdf/trip-report.ts` builds self-contained HTML (inline CSS, no scripts, every value escaped,
only https images) and `server/lib/pdf/browser-pdf.ts` prints it with Cloudflare Browser Run's `/pdf`
endpoint (`CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN`, the same credentials as link crawling),
after fetching unique photos with public-URL and redirect checks and embedding resized JPEGs
(1440 px maximum edge, up to 256 KiB each and 12 MiB total). Photo preparation has a 20-second budget;
unavailable or excess photos retain a source link and their captions. The PDF download is capped at
32 MiB and interrupted downloads return `502 PDF_RENDER_FAILED`. CJK text uses the browser's Noto CJK fonts. The
language follows `?lang=` or `Accept-Language` (`en`, `zh-Hans`, `zh-Hant`). Errors:
`503 PDF_UNAVAILABLE` when Browser Run isn't configured, `502 PDF_RENDER_FAILED` when printing failed.
The apps' **More → Export PDF…** downloads it behind a status overlay and opens the system Save dialog
(Files on iPhone and iPad).
