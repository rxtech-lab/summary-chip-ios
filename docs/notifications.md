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

Trip weather sends the trip owner tomorrow's forecast the evening before each day, and an alert when
the next 30 minutes turn bad or change. See [weather.md](weather.md).

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
