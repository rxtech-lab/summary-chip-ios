# Summary notifications

After a new summary is saved by `POST /api/v1/summaries` or
`POST /api/v1/summaries/import` (including `chippy upload`), the server schedules an
APNs alert to the owner's registered iOS and macOS installations. The alert says
“Summary added” and shows the title; it does not include the source text or summary
body. Private summaries are included. Tapping opens the summary by ID through the
authenticated API, so private and expired public links still work for the owner.
Failed or rejected creation requests do not send an alert.

Every persisted trip edit (app PUT, operations, chat agent, ingest, and MCP) queues a “Trip updated”
alert for the creator and signed-in users who opened its shared link. Each recipient needs a registered
device with notifications enabled. Anonymous link opens cannot receive push notifications.

The Vercel Workflow in `server/workflows/notify-trip-changes.ts` waits until **five minutes after the
latest edit**. Later edits extend that quiet period. A read-only agent compares the batch's first and
final saved documents and writes one short summary in the trip's language; reverted edits are omitted.
No-op or rejected edits do not queue notifications. An edit during generation invalidates the agent's
result and restarts the delay. Edits after a batch is frozen start the next batch.

The alert includes the trip title and grouped changes. Its payload carries `tripId` (equal to
`summaryId`) and the **recipient's** `userId`, so the app opens the trip for the signed-in recipient.
Shared readers are excluded if the link becomes private or expires; sharing, view history and device
ownership are checked again during delivery. The creator still receives private-trip updates.
See [trips.md](trips.md).

Tomorrow's forecast is included in the evening itinerary briefing below. Trip weather also sends
the owner a separate alert when the next 30 minutes turn bad or change. See [weather.md](weather.md).

## Trip itinerary reminders

Trips send one combined itinerary and weather briefing at **20:00 the previous day**, in the document's `timeZone`,
for each date with a planned day or transport. The first day's reminder arrives the evening before
the trip starts. Empty itinerary dates do not send alerts. A read-only agent chooses the most useful
details from tomorrow's selected plan: first departure, main activities, saved warnings/tips,
hotel check-in/check-out and the forecast for that route's places. It can recommend preparation
supported by the forecast (such as an umbrella for a rainy outdoor day). The agent body is at most
140 characters; the trip title prefix keeps the whole alert within 180 characters.

The agent has no trip-editing or web tools. Other days, unselected transport options, booking
references, confirmation codes and unrelated personal notes are excluded from its input. It writes
in the trip's language. Forecasts come from the existing weather tracker; missing forecasts and
ones older than six hours are omitted. No separate evening weather alert is sent. Live nowcast
alerts and exact leg-start reminders remain separate. If the agent fails or returns invalid text,
the reminder falls back to the saved itinerary and available forecast.

`0024_trip_reminder_briefings.sql` adds a cache keyed by the selected itinerary and forecast, so
identical plans reuse one generated briefing across installations and delivery retries. Each step
generates at most three new briefings and sends at most 20 pushes. A changed document, plan pick or
forecast during generation invalidates that result before delivery. Sharing and registration are
checked again after generation. Cached briefings expire at midnight and are removed by the
notification cron; deleting the trip or account also removes them.

At the departure of **each timed segment** in a planned/booked transport's selected option (or its
first option when none is selected), a second alert shows the departure time, route and service.
The first segment may inherit its option's departure; later segments without a time are skipped.
An option with no segments uses its own departure as one leg. Ideas and unselected options do not
send leg alerts. Local departure timestamps use the document's time zone, as in calendar sync.

Recipients are the creator and signed-in shared-link readers with registered devices, as for trip
updates. Each reminder follows that reader's saved plan selections. Sharing permissions, plan picks
and device ownership are checked during delivery. Tapping opens the trip through the existing
account-checked notification handler. Enable delivery in **Settings → Notifications** on each device.

`server/workflows/remind-trip.ts` sleeps durably until the next reminder. Creates and document edits
start a new run that fences the old one; every wake reads the current itinerary. All plan alternatives
supply wake-up times so changing a reader's pick needs no document edit. The existing five-minute
notification cron recovers failed starts and expired leases, and enrolls upcoming trips created before
this feature. The schedule checks at least daily when a trip is far ahead.

Apply **`0023_trip_reminders.sql`** and **`0024_trip_reminder_briefings.sql`** with `cd server && bun run db:migrate` before deployment. They add
schedule leases and per-event/installation/recipient receipts; account and trip deletion cascade.
Accepted installations are skipped on retries and later edits. A crash between APNs acceptance and
receipt persistence can still resend; a distinct, bounded collapse ID per event reduces duplicates.
Reminder fan-out is bounded to 20 pushes per step, with workflow retries for transient failures.
Previous-evening alerts expire at midnight; leg reminders expire ten minutes after departure,
including their APNs queue lifetime. Recovery skips expired reminders. APNs acceptance does not
guarantee display or exact delivery timing. Unconfigured APNs skips delivery.

## Enable delivery

1. Enable Push Notifications for `com.rxlab.summary-chip` in the Apple Developer
   account belonging to the app's signing team. Refresh provisioning profiles.
2. Create an APNs signing key for that team and configure the deployed server's
   `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_PRIVATE_KEY` with its `.p8` PEM contents.
   The key can contain actual newlines or literal `\n` escapes. Use a key authorized
   for both sandbox and production, or configure each deployment accordingly.
3. Apply the database migration using `cd server && bun run db:migrate` before
   deploying the updated API. It creates `push_devices` and, in `0019_trip_notifications.sql`, the
   trip notification outbox and delivery receipts. Account/trip deletion cascades to pending work.
4. Install a signed build and open **Settings → Notifications → Enable
   Notifications**. The native system prompt asks permission. Each device must opt
   in. Debug uses the sandbox APNs environment; Release uses production. The
   `SUMMARY_CHIP_PUSH_ENVIRONMENT` setting drives both the entitlement and
   registration payload; it must match the signing profile's APNs environment.
5. Sign in with the same account on two devices, add a summary through the import API or the
   MCP server (`add_summary`, see [mcp.md](mcp.md)), and confirm
   the alert opens the correct summary. Test on a signed physical iOS device and
   macOS installation; an unsigned build cannot register with APNs.

The app restores permitted registrations on launch, sign-in, and activation;
there is no unsolicited permission prompt at launch. Notification controls have
their own sheet, operation overlays, native error alerts, and mobile haptics.
Disable and sign-out stop registration with Apple and remove the server record
while credentials are available. If server cleanup fails, the app retries disabled
registration cleanup on its next signed-in activation. Foreground notifications
and notification taps verify the payload's recipient against the signed-in account.

## Device API

Both endpoints require an OAuth bearer token and accept JSON.

`POST /api/v1/devices` registers or refreshes an installation:

```json
{
  "installationId": "f6daa60d-d123-47a2-8512-596ffb2a9872",
  "token": "<hexadecimal APNs device token>",
  "environment": "sandbox",
  "platform": "ios",
  "timeZone": "Asia/Tokyo"
}
```

`environment` is `sandbox` or `production`; `platform` is `ios` or `macos`. `timeZone` is optional.
It is the device's IANA zone; an unknown zone returns `400`. The app sends it with every
registration, so trip weather alerts arrive at the right local time (see [weather.md](weather.md)).
An installation belongs to the latest authenticated account that registers it.
Token rotations replace its previous registration. `DELETE /api/v1/devices` takes
`{"installationId":"<UUID>"}` and removes only the caller's registration. Both
return `204` and do not expose device tokens in responses.

## Delivery behavior

For new summaries, the existing Next.js `after()` lifecycle runs notifications after persistence,
separately from source-document formatting. An APNs outage never changes a
successful creation response. The provider uses HTTP/2, ES256 authentication, a
10-second request timeout, and a per-summary collapse ID. Invalid/unregistered
tokens are removed; transient failures retain registrations. Credentials and
device tokens are not logged. Unconfigured APNs skips delivery.

Summary creation delivery is best effort: it has no durable outbox or retry worker, and APNs
acceptance does not guarantee that the system displays an alert (permissions,
Focus, and device connectivity affect presentation). Live delivery requires the
Apple and server configuration above.

Trip edits save their outbox in the same transaction as the revision update. `after()` starts the
workflow; if starting fails, `/api/cron/trip-notifications` recovers overdue batches every five minutes
(requires `CRON_SECRET` and the configured Vercel cron schedule). Durable `sleep()` releases compute
while waiting. Workflow steps retry agent and APNs failures; leases fence duplicate runs, and the cron
also recovers expired leases. Accepted installations are recorded so retries skip them. A crash after
APNs accepts a push but before its receipt is stored can still resend; the per-batch APNs collapse ID
reduces duplicate pending alerts. APNs acceptance does not guarantee presentation. Completed batches
and receipts are deleted, including their document snapshots. Unconfigured APNs skips delivery.

Workflow behavior follows Vercel's [workflows and steps documentation](https://github.com/vercel/workflow/blob/main/docs/content/docs/v5/foundations/workflows-and-steps.mdx).

Protocol references: [registering with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
and [sending requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).
