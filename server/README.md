# Chippy — server

Next.js 16 (App Router) + Vercel AI SDK v7 + Turso (libsql/drizzle) + Cloudflare R2.
It implements the contract in [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md): the bearer-authenticated
iOS API (`/api/v1/*`), the anonymous App Clip API (`/api/public/*`), the public share site (`/s/[slug]`),
OG image generation, and the cleanup cron.

## Free summaries and top-ups

Generation calls RxSubscription's `POST /api/v1/usage` for `daily_summary_generation`
after source validation and before AI. RxSubscription controls the allowance, reset,
point cost and available balance; the app never counts usage or embeds a limit.

Configure **Chippy's own application** in RxSubscription:

1. Create the `points` balance unit and `daily_summary_generation` usage item.
2. Set its default limit to **5**, reset policy to **daily**, and overage policy to
   **charge_balance**, using `points` with your chosen cost per extra summary.
   All users receive the allowance, including accounts with no plan or points.
3. Publish consumable top-up packs that credit `points`, with mapped Apple product IDs.
   Do not require an active plan or publish recurring paid plans.
4. Allow the app's OAuth client ID on the publishable keys. Configure matching
   secret/publishable environment keys and the service URL from `.env.example`.

Live setup verified on **2026-10-01** for Chippy's RxSubscription application:
`daily_summary_generation` gives **5 summaries per calendar day** and charges
**1 point** per extra summary. The active standalone `points_100` pack grants
**100 points for US$1.99**, and the catalog contains no recurring plans. These
values live in RxSubscription and can be changed without an app release.
Production, sandbox and Xcode return the same catalog and allowance policy;
their user balances and usage remain isolated.

**Apple purchases still require setup:** this application currently has no App Store
integration or Apple product mapping. Its catalog advertises Stripe checkout only.
Connect the Chippy app in RxSubscription's **Settings → App Store**, create
the consumable `com.rxlab.summary-chip.points100` in App Store Connect, and map it
to `points_100` before validating Apple purchase fulfillment. Keep App Store Connect
private keys in RxSubscription's settings, never in this repository.

The iOS/macOS **Settings → Summaries & Points** sheet displays the service's balance,
remaining allowance and reset time. Top-ups have their own screen; purchases use
RxSubscriptionIOS (≥ 1.2.0) and refresh the balance in place. iOS creates the client
with `useIap: true` (App Store consumables, Restore Purchases shown); the Developer ID
macOS build uses `useIap: false`, so the catalog is priced with `platform=web` and every
pack opens Stripe Checkout in the browser, fulfilled by RxSubscription's Stripe webhook.
The Stripe price on `points_100` must stay active for macOS. Share and Messages extensions,
App Clip and Siri all reach the same server enforcement.

`GET /api/v1/billing` is bearer-authenticated and returns only a publishable key,
service URL and item/unit identifiers. With separate sandbox/production keys, the
server validates Apple's signed `AppTransaction` against the bundled Apple trust
anchor and `APP_STORE_ID` before selecting sandbox. Missing proof uses production;
unsigned environment headers cannot select sandbox or production.

Xcode StoreKit testing uses `RX_SUBSCRIPTION_XCODE_API_KEY` and
`RX_SUBSCRIPTION_XCODE_PUBLISHABLE_KEY` (prefixes `rxs_xcode_` and `rxs_pk_xcode_`).
Debug builds send `x-storekit-environment: xcode` when StoreKit reports `.xcode`;
both the storefront and summary usage then use that environment's separate balance.
On deployed servers, add authorized RxAuth user subjects to the comma-separated
`RX_SUBSCRIPTION_XCODE_USER_IDS`. Other users receive `403 XCODE_BILLING_NOT_ALLOWED`.
Xcode's locally signed transactions cannot prove identity or an Apple environment;
the authenticated subject and server configuration authorize this test-only route.
Local development does not require a tester list. A dedicated Xcode server may use
`RX_SUBSCRIPTION_ENVIRONMENT=xcode` with matching named or single-environment keys.
Enable a StoreKit configuration in the Xcode scheme containing consumable product
IDs matching the top-up packs published in RxSubscription's Xcode catalog.

Usage measures **accepted generation attempts**. Rejected/invalid requests do not
spend usage. Once RxSubscription accepts an attempt it stays counted (and any
overage stays charged) if AI or persistence later fails: the deployed usage API
does not support refunds. Each operation sends a unique metering idempotency key;
a new user retry is a new attempt.

Unconfigured local development may skip metering. Production and partially
configured servers fail closed, as do service outages and unknown usage items.

### Chat points

Chat (`POST /api/v1/chat`) has no free allowance; every turn spends `points` at the
chat model's **API list price**. Before the model runs, the server reserves 1 point
(`POST /api/v1/balances/reserve`); an empty balance is refused with
`402 CHAT_POINTS_EXHAUSTED`, which the app answers with its top-up sheet. When the
stream ends (finished, failed or the client hung up), the input, cached-input and
output tokens of every step, tool rounds included, are priced from the AI Gateway
model catalog. That cost is converted at `CHAT_POINTS_PER_USD` (default **50**, which
matches 100 points for US$1.99), rounded up to whole points, and settled against the
reservation. The model id is the ledger description. Cost above the hold is taken from
the free balance; whatever that can't cover is logged as a shortfall, not an error.
A model with no listed price is charged the 1-point minimum. Embedding calls made by
the search tool are not charged. Chat uses the same billing environment headers as
generation. Unconfigured local development skips chat billing.

### Source document points

Keeping a summary's source (links, shared text, opted-in local files) runs the document
agent, which reformats the source as a Markdown document. It is billed like the summary
it belongs to: the free allowance is used first, then points. While the summary comes
out of the free allowance (`chargedUnits: 0` from the usage API) the document is
included at no cost. Past the allowance, once the summary is saved, the server reserves
1 point under `document:<summaryId>`, runs the agent after the response, and settles
every agent step's tokens at the text model's API price (`CHAT_POINTS_PER_USD`).
With an empty balance (or billing unreachable) the agent does not run and the plain
extracted text is kept instead; the summary itself never fails for this. A failed
agent run releases the hold (0 points).

## Layout

```
app/
  page.tsx                          landing page
  s/[slug]/page.tsx                 public summary page (+ og/twitter/apple-itunes-app meta)
  s/[slug]/og.png/route.ts          OG PNG (302 to R2 custom domain when public, else streamed)
  s/[slug]/source/route.ts          302 → signed R2 URL of the uploaded PDF
  .well-known/apple-app-site-association/route.ts
  api/v1/{uploads,summaries,summaries/import,summaries/[id],summaries/[id]/image,facets,views,chat}
  api/v1/account/deletion           schedule / read / cancel account deletion (7-day grace)
  api/v1/legal/{privacy,terms}      markdown legal documents (public)
  api/v1/api-keys[/[id]]            list / create / rename / revoke MCP API keys (hashed)
  api/mcp                           hosted MCP server (OAuth or API key, stateless) — docs/mcp.md
  api/public/summaries/[slug]       App Clip read
  api/cron/cleanup                  retire OG images of expired links + orphan uploads
  api/cron/account-deletion         hourly: purge accounts whose deletion came due
lib/
  auth/bearer.ts                    RxAuth JWT verification (JWKS, RS256, client_id allow list)
  mcp/server.ts                     MCP tools: add_summary, search_summaries, list_summaries
  http/                             handler wrapper, error envelope, cron auth, app-version gating
  db/                               drizzle schema + libsql client
  extract/                          URL fetch (SSRF-guarded) + Cloudflare Browser Rendering, Readability/linkedom, unpdf
  ai/                               models, structured summarisation, mock provider, chat agent
  og/                               SVG sanitiser, fallback art, fonts, next/og renderer
  services/                         summaries, views/history, uploads, search (vector + LIKE), embeddings, cleanup
drizzle/                            migrations (generated by drizzle-kit)
tests/                              vitest (in-memory libsql, memory object store, mock AI)
```

## Setup

```bash
bun install
cp .env.example .env         # fill in the values below
```

### Turso

```bash
turso db create summary-chip
turso db show summary-chip --url         # → TURSO_DATABASE_URL
turso db tokens create summary-chip      # → TURSO_AUTH_TOKEN
bun run db:migrate                       # applies drizzle/ migrations
```

For local development `TURSO_DATABASE_URL=file:local.db` works too. After changing `lib/db/schema.ts`
run `bun run db:generate` and commit the new migration. Turso Cloud databases run in MVCC mode, which
does not support virtual tables (FTS5) — keep migrations to plain tables, indexes and triggers.

### Cloudflare R2

1. Create a bucket (e.g. `summary-chip`) → `R2_BUCKET`; your account id → `R2_ACCOUNT_ID`.
2. Create an R2 API token with *Object Read & Write* on that bucket → `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`.
3. Add a CORS rule so iOS can `PUT` presigned uploads (native clients don't need CORS, but it doesn't hurt):
   `AllowedMethods: [PUT, GET]`, `AllowedHeaders: [content-type]`.
4. Optional but recommended: connect a custom domain to the bucket (R2 → bucket → Settings → Custom
   Domains, e.g. `cdn.summary.rxlab.app`) and set `R2_PUBLIC_BASE_URL=https://cdn.summary.rxlab.app`.
   Public OG images are then served from Cloudflare's CDN (`/s/<slug>/og.png` 302s there and the page's
   `og:image` uses it directly). Keys carry a random suffix and are rotated when a summary is made
   private, so its old public URL stops resolving (≤ 5 min CDN cache). PDFs are never exposed through
   the domain — they always use short-lived signed URLs.

Object keys: `uploads/<sha256(owner)[0:24]>/<uuid>.pdf` (PDF uploads) and `og/<summaryId>-<ts>-<random>.png`
(OG images). The bucket stays private; everything is served through the app or short-lived signed URLs.

### Cloudflare Browser Rendering (optional)

Set `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` (token with *Browser Rendering - Edit*) to render
shared links in headless Chromium via the `/browser-rendering/content` endpoint. HTML pages are rendered
after the SSRF-guarded fetch, so JavaScript-built content is summarised. Pages that block or time out on a
plain fetch are retried in the browser. If rendering fails, the static HTML is used instead. When the vars
are unset, only the plain fetch runs.

### Auth

`AUTH_ISSUER` (default `https://auth.rxlab.app`) must serve `/.well-known/jwks.json`. Tokens must be RS256,
have `sub`, `exp` and a `client_id` in `IOS_OAUTH_CLIENT_ID` / `RXLAB_ALLOWED_CLIENT_IDS`.

The MCP endpoint supports a separate OAuth authorization-code flow with S256 PKCE and public
dynamic client registration, alongside existing personal API keys. Register one confidential
RxAuth client for Chippy MCP with redirect URI `https://summary.rxlab.app/api/mcp/oauth/callback`
and `openid profile email` scopes. Set `MCP_RXAUTH_CLIENT_ID` / `MCP_RXAUTH_CLIENT_SECRET`, configure
the canonical `MCP_RESOURCE_URL`, and apply database migration `0016_mcp_oauth` before enabling
OAuth connections. These server credentials never go in the plugin package. See
[MCP OAuth setup](../docs/mcp.md#oauth-sign-in) for endpoints, scopes, and local testing.

### AI

`AI_MODEL` defaults to `openai/gpt-5-mini` through the Vercel AI Gateway. On Vercel, OIDC authenticates
the gateway automatically; elsewhere set `AI_GATEWAY_API_KEY` (`AI_GATEWAY_KEY` is accepted too).

Text sources that contain a URL first go through an evaluation model (`AI_EVALUATION_MODEL`, default
`typesafe-ai/jev`) that decides whether the text is really a shared link — e.g. a Xiaohongshu share
snippet "teaser… https://xhslink.cn/… 先复制文字，再进【小红书】…". Links are fetched like a `url` source
(falling back to the text if the page cannot be read); everything else is summarised as text. Text
without a URL skips the evaluation, and `AI_EVALUATION_MODEL=off` always summarises the text.

Set `AI_IMAGE_MODEL` (e.g. `google/gemini-3.1-flash-lite-image`) to enable `imageStyle: "illustration"`.
Gemini image models are language models on the Gateway, so they are called with `generateText` and the
drawing is read from `result.files`; other ids (e.g. `openai/gpt-image-2`) go through `generateImage`.
The server randomly assigns a cover palette from eight distinct color families for new summaries,
imports and image regeneration. It excludes the owner's five most recently updated chip palettes
and, when regenerating, the chip's current palette. Colors, mode and accent are saved in the existing
`summaries.theme` JSON; no migration is needed. Existing covers keep their colors until regenerated.
Both graphic and illustration generation use this stored palette, so similar topics can have
different colors and clients see consistent artwork.

The image model draws text-free 16:9 artwork (background, shapes, line work and illustrated subject).
`lib/og/generated.ts` cover-crops it to a 1200×630 PNG with `sharp`; the card template overlays the
headline, category, source and "Chippy" wordmark. The artwork alone is used for library tiles. If
the env var is unset or the call fails, the graphic style uses the same assigned palette.

## Scripts

| Command | What it does |
|---|---|
| `bun run dev` | Next dev server. `SUMMARY_MOCK_SERVICES=true` uses the mock AI + in-memory store (non-production only). |
| `bun run build` | Production build (no env vars needed at build time; clients are created lazily). |
| `bun run lint` / `bun run typecheck` | ESLint / `tsc --noEmit`. |
| `bun run test` | Vitest: in-memory libsql migrated with the real migrations, mock AI, memory R2. |
| `bun run test:e2e` | Playwright API tests (`tests/e2e`) against a real `next dev` on :3100 with mock services, a fresh `.e2e/e2e.db`, and bearer tokens from a local mock issuer on :3101 (`tests/e2e/mock-issuer.ts`). No browsers needed. CI: `.github/workflows/server-tests.yaml`. |
| `bun run db:generate` / `bun run db:migrate` | drizzle-kit generate / apply migrations to `TURSO_DATABASE_URL`. |
| `bun run db:backfill-embeddings` | Embed every summary missing a search embedding (or one from an older `AI_EMBEDDING_MODEL`). |
| `TURSO_DATABASE_URL=file:local.db bun scripts/seed-dev.ts` | Seed one sample summary locally (mock AI). `OG_OUT=og.png` also writes its OG image. |

## Deploying (Vercel)

1. Create a Vercel project with root directory `server/`, framework Next.js, install command `bun install`.
2. Add every variable from `.env.example` (production + preview). Generate `CRON_SECRET` with
   `openssl rand -hex 32`.
3. Run `bun run db:migrate` against the production database before (or right after) the first deploy,
   then `bun run db:backfill-embeddings` once so existing summaries are found by semantic search.
4. Point `summary.rxlab.app` at the project and set `NEXT_PUBLIC_SITE_URL` accordingly.

`vercel.json` schedules `GET /api/cron/cleanup` daily at 03:00 UTC (Hobby-plan safe). Summaries are
never deleted by expiry — the TTL only ends the public link, and expired links are already hidden from
everyone but the owner before the cron runs. The cron moves the OG image of recently expired links to
a fresh key (so the CDN URL dies), deletes uploads that were never attached to a summary within a day,
and embeds up to 500 summaries still missing a search embedding.

Function limits: `POST /api/v1/summaries/import`, `POST /api/v1/summaries/:id/image` and `POST /api/v1/chat`
set `maxDuration = 120`; `POST /api/v1/summaries` (document agent runs after the response), `POST /api/mcp`
and the cron allow 300.

## Universal links & App Clip

* `/.well-known/apple-app-site-association` is served as JSON (no extension) with `applinks` for
  `P9KK452K8P.com.rxlab.summary-chip` on `/s/*`, `appclips` for `…summary-chip.Clip`, and
  `webcredentials`. The team id comes from `APPLE_TEAM_ID`.
* The iOS app needs the `applinks:summary.rxlab.app` / `appclips:summary.rxlab.app` associated domains.
* In App Store Connect, add an **Advanced App Clip Experience** for `https://summary.rxlab.app/s/` (prefix)
  so any shared link opens the App Clip card. The page's `apple-itunes-app` meta already carries
  `app-clip-bundle-id=com.rxlab.summary-chip.Clip, app-clip-display=card` (plus `app-id` when
  `APP_STORE_ID` is set).
* Apple caches AASA via its CDN; after changes, verify with
  `curl https://app-site-association.cdn-apple.com/a/v1/summary.rxlab.app`.

## App versions and incompatible changes

Every request from the iOS/macOS app (and its extensions) carries the app's version
(`SummaryKit/Networking/AppVersionHeaders.swift`):

| Header | Example | Source |
|--------|---------|--------|
| `X-App-Version` | `1.9.0` | `CFBundleShortVersionString` (`MARKETING_VERSION`) |
| `X-App-Build` | `42` | `CFBundleVersion` |
| `X-App-Platform` | `ios` / `macos` / `visionos` | build platform |

The server reads them in `lib/http/app-version.ts`. API logs include the app version too. Requests without
a valid `X-App-Version` (tests, scripts, and app builds up to 1.9.x, released before the header) are
**always accepted**.

**If you add a feature that older app versions can't handle, gate it so the app shows an update
dialog instead of breaking.** Trips are an example: they need app 1.9.0 or later.

1. Add the feature and the first app version that supports it to `FEATURE_MIN_APP_VERSIONS`
   (`lib/http/app-version.ts`), e.g. `trips: "1.9.0"`. Use the version the app will ship in
   (the release tag), not the current one.
2. Gate the routes: `withApiAuth(request, action, { feature: "trips" })` (also on `withPublicApi`),
   or call `requireAppFeature(request, "trips")` inside a handler when only some requests need it
   (e.g. `POST /api/v1/chat` with a `tripId`).
3. Older apps then get `426 APP_UPDATE_REQUIRED`:

   ```json
   { "error": { "code": "APP_UPDATE_REQUIRED",
       "message": "This feature needs Chippy 1.9.0 or later. Update the app to keep using it.",
       "details": { "feature": "trips", "requiredVersion": "1.9.0", "currentVersion": "1.8.0",
                    "updateUrl": "https://apps.apple.com/app/id…" } } }
   ```

   The app shows a native **Update Chippy** alert: "This feature needs Chippy {requiredVersion} or later."
   (`AppUpdateCenter` + `.appUpdateAlert()` in SummaryKit). **Update** opens `updateUrl` on iOS (the App
   Store listing, when `APP_STORE_ID` is set) and runs a Sparkle update check on macOS. Error messages
   in the share extensions say the same.
4. Add a test that a request with an older `X-App-Version` gets the 426 (see `tests/integration/trips.test.ts`).

Don't gate changes that older apps already tolerate (new optional fields, new enum values that decode as
"other"). For a breaking change to an *existing* endpoint, prefer keeping the old response for apps where
`supportsAppFeature(request, feature)` is false; use `requireAppFeature` only when the old behaviour
can't be kept.

## Behaviour notes

* **Visibility.** Private summaries 404 on `/s/[slug]`, `/api/public/*`, `og.png` and `source`. The owner
  still sees them in `/api/v1`, and `og.png` / `source` also accept the owner's `Authorization: Bearer`
  token (served with `Cache-Control: private, no-store`). Public OG images are cached for 5 minutes.
* **View counts** increase on human page views and App Clip reads (link-preview bots are ignored) and on
  `POST /api/v1/views` by non-owners (which also records history).
* **Search** is hybrid, for `GET /api/v1/summaries?q=` and the chat agent's `searchSummaries` tool. Each
  summary is embedded (`AI_EMBEDDING_MODEL`, default `openai/text-embedding-3-small`) from its card fields
  plus the start of the original text into `summary_embeddings` as a libSQL `vector32` blob, on create and
  on rename/retag. A natural-language query matches a summary whose cosine distance
  (`vector_distance_cos`) is within `SEARCH_MAX_DISTANCE` (default 0.65) **or** that contains every
  keyword; keyword hits get a ranking boost, and results come most relevant first, paged with an offset
  cursor. The scan is exact (no vector index — Turso's MVCC mode has no virtual tables), which is fine for
  per-user libraries. Keywords: up to 8 whitespace tokens, every one must appear (case-insensitive `LIKE`,
  wildcards escaped) in the title, summary, highlights, tags, keywords, category or site name; CJK works as
  substring matching. With `AI_EMBEDDING_MODEL=off`, or if the query can't be embedded, search falls back
  to keywords alone.
* **URL fetching** only allows public http(s) targets: every DNS answer and every redirect hop is checked
  against private/loopback/link-local ranges; 15 s timeout and 10 MB cap.
* **OG images**: fonts are subset on the fly from Google Fonts (`Noto Sans` / `SC` / `TC` / `JP` / `KR`
  based on the glyphs); if the fetch fails the card still renders with the bundled Latin font. The card
  uses geometric decoration (layered shapes, hairlines, dot grids) — the theme emoji is not drawn.

## Summary push notifications

API creation and CLI imports send the owner's registered iOS/macOS devices a
“Summary added” push after the summary is saved. Enable notifications in the app's
Settings sheet. Apply the `push_devices` migration and configure the server's
`APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_PRIVATE_KEY` for live delivery; see
[notification setup and API](../docs/notifications.md).

## Flight tracking

Flight segments in trips are tracked by a Vercel Workflow per flight (`workflows/track-flight.ts`),
which polls AeroDataBox, stores the result, sends delay/gate/boarding/landing alerts and drives the
flight Live Activity. Apps only read the stored copy. Set `AERODATABOX_API_KEY` and apply the
`flights` migration; see [flight tracking](../docs/flights.md).
